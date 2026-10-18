package job

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"strconv"
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

// PageRenderArgs asks for a whole page rendered as JPEG so Rails can send it
// to Mistral OCR for text-region detection. Unlike render_pdf_crop it is keyed
// by page_layouts.id and reports back on its own callback, so it never
// triggers Claude OCR.
type PageRenderArgs struct {
	PageLayoutID int64             `json:"page_layout_id"`
	PDFPath      string            `json:"pdf_path"`
	Page         int               `json:"page"`
	Trace        map[string]string `json:"trace,omitempty"`
}

func (PageRenderArgs) Kind() string { return "render_pdf_page" }

// PageOutputName is the file name of a rendered page inside RenderOutputDir.
// The "page-" prefix keeps it apart from crops, which are named by
// ocr_request id.
func PageOutputName(pageLayoutID int64) string {
	return "page-" + strconv.FormatInt(pageLayoutID, 10) + ".jpg"
}

type PageWorker struct {
	river.WorkerDefaults[PageRenderArgs]

	PDFRootDir      string
	RenderOutputDir string
	Callback        *callback.Client
	Cache           *cache.Cache
	Opts            render.Options
	Logger          *slog.Logger
}

func (w *PageWorker) Work(ctx context.Context, j *river.Job[PageRenderArgs]) error {
	args := j.Args
	start := time.Now()

	if len(args.Trace) > 0 {
		ctx = otel.GetTextMapPropagator().Extract(ctx, propagation.MapCarrier(args.Trace))
	}
	ctx, span := otel.Tracer("render").Start(ctx, "render_pdf_page",
		trace.WithSpanKind(trace.SpanKindConsumer),
		trace.WithAttributes(
			attribute.Int64("page_layout_id", args.PageLayoutID),
			attribute.String("pdf_path", args.PDFPath),
			attribute.Int("page", args.Page),
		),
	)
	defer span.End()

	pdfAbs, err := locatePDF(w.PDFRootDir, args.PDFPath)
	if err != nil {
		span.SetStatus(codes.Error, "bad pdf path")
		span.RecordError(err)
		w.Logger.Warn("rejecting page job: bad pdf",
			"page_layout_id", args.PageLayoutID, "pdf_path", args.PDFPath, "err", err.Error())
		return err
	}

	// Same cached 300 DPI bitmap the crop worker uses, so a later click on a
	// region of this page is a cache hit.
	pageImg, pdfPageCount, cacheHit, err := render.PageBitmap(ctx, w.Cache, pdfAbs, args.Page, w.Opts)
	if err != nil {
		span.SetStatus(codes.Error, "page bitmap")
		span.RecordError(err)
		return fmt.Errorf("page bitmap: %w", err)
	}

	jpegBytes, finalRect, err := render.EncodePage(pageImg, w.Opts)
	if err != nil {
		span.SetStatus(codes.Error, "encode")
		span.RecordError(err)
		return fmt.Errorf("encode page: %w", err)
	}
	span.SetAttributes(
		attribute.Bool("cache_hit", cacheHit),
		attribute.Int("pdf_page_count", pdfPageCount),
		attribute.Int("output_w", finalRect.Dx()),
		attribute.Int("output_h", finalRect.Dy()),
		attribute.Int("output_bytes", len(jpegBytes)),
	)

	if err := os.MkdirAll(w.RenderOutputDir, 0o755); err != nil {
		span.RecordError(err)
		return fmt.Errorf("mkdir output dir: %w", err)
	}
	outPath := filepath.Join(w.RenderOutputDir, PageOutputName(args.PageLayoutID))
	if err := writeAtomic(outPath, jpegBytes); err != nil {
		span.RecordError(err)
		return fmt.Errorf("write output: %w", err)
	}

	renderMs := time.Since(start).Milliseconds()
	cbBody := callback.PageRenderDoneBody{RenderMs: int(renderMs), PDFPageCount: pdfPageCount}
	if err := w.Callback.PageRenderDone(ctx, args.PageLayoutID, cbBody); err != nil {
		span.SetStatus(codes.Error, "callback")
		span.RecordError(err)
		return fmt.Errorf("notify Rails: %w", err)
	}

	w.Logger.Info("page_render_done",
		"page_layout_id", args.PageLayoutID,
		"page", args.Page,
		"pdf_path", args.PDFPath,
		"cache_hit", cacheHit,
		"render_ms", renderMs,
		"output_bytes", len(jpegBytes),
		"output_w", finalRect.Dx(),
		"output_h", finalRect.Dy(),
	)
	return nil
}
