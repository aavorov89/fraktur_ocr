package render

// MuPDF is not safe to call from several goroutines in one process, even with
// one fz_context per document: go-fitz creates its contexts without lock
// callbacks, and MuPDF keeps some decoder state in process-wide globals (the
// OpenJPEG allocator context used for JPXDecode images, for one). Two
// concurrent renders of JPEG 2000 pages race on that global and segfault the
// whole service.
//
// So the service never calls MuPDF itself. Every page count and rasterization
// runs in a short-lived child process: this same binary, re-executed with
// childArg as its first argument. Each child has its own copy of MuPDF's
// globals, and a crash in one fails only that job instead of killing the
// worker.
//
// Protocol: the child writes one JSON line ({"page_count":N}) to stdout,
// followed by the page as PNG bytes when -page > 0. On failure it prints a
// message to stderr and exits non-zero.

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"image/png"
	"io"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"

	"github.com/gen2brain/go-fitz"
)

const childArg = "__mupdf-child"

// MaybeRunChild turns the process into a one-shot MuPDF child and exits if it
// was started as one. Call it first thing in main (and in TestMain for tests
// of this package, since the test binary is what gets re-executed there).
func MaybeRunChild() {
	if len(os.Args) < 2 || os.Args[1] != childArg {
		return
	}
	if err := runChild(os.Args[2:], os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	os.Exit(0)
}

type childHeader struct {
	PageCount int `json:"page_count"`
}

func runChild(args []string, stdout io.Writer) error {
	fs := flag.NewFlagSet(childArg, flag.ContinueOnError)
	pdfPath := fs.String("pdf", "", "PDF to open")
	page := fs.Int("page", 0, "1-indexed page to rasterize; 0 only counts pages")
	dpi := fs.Float64("dpi", 300, "rasterization DPI")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *pdfPath == "" {
		return errors.New("-pdf is required")
	}

	doc, err := fitz.New(*pdfPath)
	if err != nil {
		return fmt.Errorf("open pdf: %w", err)
	}
	defer doc.Close()
	pageCount := doc.NumPage()

	w := bufio.NewWriter(stdout)
	if err := json.NewEncoder(w).Encode(childHeader{PageCount: pageCount}); err != nil {
		return err
	}
	if *page > 0 {
		if *page > pageCount {
			return fmt.Errorf("page %d out of range (1..%d)", *page, pageCount)
		}
		// go-fitz uses 0-indexed pages.
		img, err := doc.ImageDPI(*page-1, *dpi)
		if err != nil {
			return fmt.Errorf("rasterize: %w", err)
		}
		if err := png.Encode(w, img); err != nil {
			return fmt.Errorf("encode png: %w", err)
		}
	}
	return w.Flush()
}

var executable = sync.OnceValues(os.Executable)

// runMuPDF runs one child for pdfPath. page == 0 only counts pages and returns
// nil PNG bytes.
func runMuPDF(ctx context.Context, pdfPath string, page int, dpi float64) (int, []byte, error) {
	if page < 0 {
		return 0, nil, fmt.Errorf("page %d out of range", page)
	}
	exe, err := executable()
	if err != nil {
		return 0, nil, fmt.Errorf("locate own executable: %w", err)
	}

	cmd := exec.CommandContext(ctx, exe, childArg,
		"-pdf", pdfPath,
		"-page", strconv.Itoa(page),
		"-dpi", strconv.FormatFloat(dpi, 'f', -1, 64),
	)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	if err := cmd.Run(); err != nil {
		if ctxErr := ctx.Err(); ctxErr != nil {
			return 0, nil, fmt.Errorf("mupdf child: %w", ctxErr)
		}
		if msg := firstLine(stderr.String()); msg != "" {
			return 0, nil, fmt.Errorf("mupdf child: %s (%w)", msg, err)
		}
		return 0, nil, fmt.Errorf("mupdf child: %w", err)
	}

	headerLine, rest, ok := bytes.Cut(stdout.Bytes(), []byte("\n"))
	if !ok {
		return 0, nil, errors.New("mupdf child: missing header line")
	}
	var h childHeader
	if err := json.Unmarshal(headerLine, &h); err != nil {
		return 0, nil, fmt.Errorf("mupdf child: bad header: %w", err)
	}
	if page > 0 && len(rest) == 0 {
		return 0, nil, errors.New("mupdf child: no image data")
	}
	if page == 0 {
		rest = nil
	}
	return h.PageCount, rest, nil
}

// firstLine keeps child errors short: a crashing child prints a full
// goroutine dump, and only its first line ("SIGSEGV: segmentation
// violation") belongs in the job's error.
func firstLine(s string) string {
	s = strings.TrimSpace(s)
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		s = s[:i]
	}
	const max = 500
	if len(s) > max {
		s = s[:max]
	}
	return s
}
