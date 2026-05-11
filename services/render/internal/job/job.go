package job

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/riverqueue/river"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/trace"

	"github.com/fraktur-ocr/services/render/internal/cache"
	"github.com/fraktur-ocr/services/render/internal/callback"
	"github.com/fraktur-ocr/services/render/internal/render"
)

type RectPts struct {
	X float64 `json:"x"`
	Y float64 `json:"y"`
	W float64 `json:"w"`
	H float64 `json:"h"`
}

type RenderArgs struct {
	OCRRequestID int64   `json:"ocr_request_id"`
	PDFPath      string  `json:"pdf_path"`
	Page         int     `json:"page"`
	RectPts      RectPts `json:"rect_pts"`
	// Trace carries the W3C trace context Rails injected when enqueueing.
	// Empty for jobs that don't originate from a traced request.
	Trace map[string]string `json:"trace,omitempty"`
}

func (RenderArgs) Kind() string { return "render_pdf_crop" }

type Worker struct {
	river.WorkerDefaults[RenderArgs]

	PDFRootDir      string
	RenderOutputDir string
	Callback        *callback.Client
	Cache           *cache.Cache
	Opts            render.Options
	Logger          *slog.Logger
}

func (w *Worker) Work(ctx context.Context, j *river.Job[RenderArgs]) error {
	args := j.Args
	start := time.Now()

	// Continue the Rails-originated trace. If args.Trace is empty (e.g. job
	// enqueued from outside the Rails pipeline) the propagator returns ctx
	// unchanged and we start a fresh root span.
	if len(args.Trace) > 0 {
		ctx = otel.GetTextMapPropagator().Extract(ctx, propagation.MapCarrier(args.Trace))
	}
	tracer := otel.Tracer("render")
	ctx, span := tracer.Start(ctx, "render_pdf_crop",
		trace.WithSpanKind(trace.SpanKindConsumer),
		trace.WithAttributes(
			attribute.Int64("ocr_request_id", args.OCRRequestID),
			attribute.String("pdf_path", args.PDFPath),
			attribute.Int("page", args.Page),
		),
	)
	defer span.End()

	pdfAbs, err := resolveSafePath(w.PDFRootDir, args.PDFPath)
	if err != nil {
		span.SetStatus(codes.Error, "bad pdf path")
		span.RecordError(err)
		w.Logger.Warn("rejecting job: bad pdf path",
			"ocr_request_id", args.OCRRequestID, "pdf_path", args.PDFPath, "err", err.Error())
		return river.JobCancel(err)
	}

	st, err := os.Stat(pdfAbs)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			w.Logger.Warn("rejecting job: pdf missing",
				"ocr_request_id", args.OCRRequestID, "pdf_path", args.PDFPath)
			return river.JobCancel(fmt.Errorf("pdf not found: %s", args.PDFPath))
		}
		return fmt.Errorf("stat pdf: %w", err)
	}
	if st.IsDir() {
		return river.JobCancel(fmt.Errorf("pdf path is a directory: %s", args.PDFPath))
	}

	pageImg, pdfPageCount, cacheHit, err := render.PageBitmap(ctx, w.Cache, pdfAbs, args.Page, w.Opts)
	if err != nil {
		span.SetStatus(codes.Error, "page bitmap")
		span.RecordError(err)
		return fmt.Errorf("page bitmap: %w", err)
	}
	span.SetAttributes(
		attribute.Bool("cache_hit", cacheHit),
		attribute.Int("pdf_page_count", pdfPageCount),
	)

	rect := render.RectPts{X: args.RectPts.X, Y: args.RectPts.Y, W: args.RectPts.W, H: args.RectPts.H}
	jpegBytes, finalRect, err := render.CropAndEncode(pageImg, rect, w.Opts)
	if err != nil {
		span.SetStatus(codes.Error, "crop+encode")
		span.RecordError(err)
		return fmt.Errorf("crop+encode: %w", err)
	}
	span.SetAttributes(
		attribute.Int("output_w", finalRect.Dx()),
		attribute.Int("output_h", finalRect.Dy()),
		attribute.Int("output_bytes", len(jpegBytes)),
	)

	if err := os.MkdirAll(w.RenderOutputDir, 0o755); err != nil {
		span.RecordError(err)
		return fmt.Errorf("mkdir output dir: %w", err)
	}
	outPath := filepath.Join(w.RenderOutputDir, strconv.FormatInt(args.OCRRequestID, 10)+".jpg")
	if err := writeAtomic(outPath, jpegBytes); err != nil {
		span.RecordError(err)
		return fmt.Errorf("write output: %w", err)
	}

	renderMs := time.Since(start).Milliseconds()

	// HTTP rather than pg_notify because pure-NOTIFY required a long-lived listener.
	// The body carries timing + PDF metadata for the BetterStack Warehouse
	// analytics pipeline on the Rails side.
	cbBody := callback.RenderDoneBody{
		RenderMs:     int(renderMs),
		PDFPageCount: pdfPageCount,
		RenderDPI:    int(w.Opts.CanonicalDPI),
	}
	if err := w.Callback.RenderDone(ctx, args.OCRRequestID, cbBody); err != nil {
		span.SetStatus(codes.Error, "callback")
		span.RecordError(err)
		return fmt.Errorf("notify Rails: %w", err)
	}

	w.Logger.Info("render_done",
		"ocr_request_id", args.OCRRequestID,
		"page", args.Page,
		"pdf_path", args.PDFPath,
		"cache_hit", cacheHit,
		"render_ms", renderMs,
		"output_bytes", len(jpegBytes),
		"output_w", finalRect.Dx(),
		"output_h", finalRect.Dy(),
		"pdf_page_count", pdfPageCount,
	)
	return nil
}

// resolveSafePath joins root and rel, then ensures the cleaned path is still
// rooted at root — defends against ".." traversal in user-supplied input.
func resolveSafePath(root, rel string) (string, error) {
	if rel == "" {
		return "", errors.New("empty pdf_path")
	}
	if filepath.IsAbs(rel) {
		return "", fmt.Errorf("pdf_path must be relative: %s", rel)
	}
	rootAbs, err := filepath.Abs(root)
	if err != nil {
		return "", fmt.Errorf("abs root: %w", err)
	}
	joined := filepath.Clean(filepath.Join(rootAbs, rel))
	if joined != rootAbs && !strings.HasPrefix(joined, rootAbs+string(os.PathSeparator)) {
		return "", fmt.Errorf("pdf_path escapes root: %s", rel)
	}
	return joined, nil
}

func writeAtomic(path string, data []byte) error {
	tmp := path + ".tmp"
	f, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o644)
	if err != nil {
		return err
	}
	if _, err := f.Write(data); err != nil {
		f.Close()
		os.Remove(tmp)
		return err
	}
	if err := f.Sync(); err != nil {
		f.Close()
		os.Remove(tmp)
		return err
	}
	if err := f.Close(); err != nil {
		os.Remove(tmp)
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		os.Remove(tmp)
		return err
	}
	return nil
}
