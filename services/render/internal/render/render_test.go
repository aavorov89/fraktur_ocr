package render

import (
	"bytes"
	"context"
	"image/jpeg"
	"os"
	"path/filepath"
	"testing"

	"github.com/fraktur-ocr/services/render/internal/cache"
	"github.com/fraktur-ocr/services/render/testdata"
)

// US Letter at 72 dpi → 612 x 792 pt.
const (
	pageWidthPts  = 612
	pageHeightPts = 792
)

func writeFixture(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "sample.pdf")
	if err := os.WriteFile(path, testdata.BuildMinimalPDF(pageWidthPts, pageHeightPts), 0o644); err != nil {
		t.Fatalf("write fixture: %v", err)
	}
	return path
}

func TestRenderCropProducesValidJPEG(t *testing.T) {
	pdfPath := writeFixture(t)
	c, err := cache.Open(t.TempDir(), 1<<30)
	if err != nil {
		t.Fatalf("cache.Open: %v", err)
	}
	defer c.Close()

	opts := Options{CanonicalDPI: 300, MaxLongSidePx: 2000, JPEGQuality: 92}

	ctx := context.Background()
	pageImg, pageCount, hit, err := PageBitmap(ctx, c, pdfPath, 1, opts)
	if err != nil {
		t.Fatalf("PageBitmap: %v", err)
	}
	if hit {
		t.Fatal("expected cache miss on first render")
	}
	if pageCount != 1 {
		t.Errorf("page count = %d, want 1", pageCount)
	}

	// 200x100 pt rectangle near the top-left → at 300dpi → ~833x416 px.
	rect := RectPts{X: 0, Y: 0, W: 200, H: 100}
	jpegBytes, finalRect, err := CropAndEncode(pageImg, rect, opts)
	if err != nil {
		t.Fatalf("CropAndEncode: %v", err)
	}

	cfg, err := jpeg.DecodeConfig(bytes.NewReader(jpegBytes))
	if err != nil {
		t.Fatalf("jpeg.DecodeConfig: %v", err)
	}

	const pxPerPt = 300.0 / 72.0
	expectedW := int(rect.W * pxPerPt)
	expectedH := int(rect.H * pxPerPt)

	if !within(cfg.Width, expectedW, 0.05) {
		t.Errorf("width %d not within 5%% of expected %d", cfg.Width, expectedW)
	}
	if !within(cfg.Height, expectedH, 0.05) {
		t.Errorf("height %d not within 5%% of expected %d", cfg.Height, expectedH)
	}
	if max(cfg.Width, cfg.Height) > opts.MaxLongSidePx {
		t.Errorf("long side %d exceeds cap %d", max(cfg.Width, cfg.Height), opts.MaxLongSidePx)
	}
	if finalRect.Dx() != cfg.Width || finalRect.Dy() != cfg.Height {
		t.Errorf("returned rect %v disagrees with decoded jpeg %dx%d", finalRect, cfg.Width, cfg.Height)
	}

	// Second call must hit cache.
	if _, _, hit, err := PageBitmap(ctx, c, pdfPath, 1, opts); err != nil || !hit {
		t.Errorf("expected cache hit on second call, got hit=%v err=%v", hit, err)
	}
}

func TestDownsampleEnforcesLongSideCap(t *testing.T) {
	pdfPath := writeFixture(t)
	c, err := cache.Open(t.TempDir(), 1<<30)
	if err != nil {
		t.Fatalf("cache.Open: %v", err)
	}
	defer c.Close()

	opts := Options{CanonicalDPI: 300, MaxLongSidePx: 500, JPEGQuality: 80}
	pageImg, _, _, err := PageBitmap(context.Background(), c, pdfPath, 1, opts)
	if err != nil {
		t.Fatalf("PageBitmap: %v", err)
	}
	// Crop the whole page; raw size is well over 500.
	rect := RectPts{X: 0, Y: 0, W: pageWidthPts, H: pageHeightPts}
	jpegBytes, _, err := CropAndEncode(pageImg, rect, opts)
	if err != nil {
		t.Fatalf("CropAndEncode: %v", err)
	}
	cfg, err := jpeg.DecodeConfig(bytes.NewReader(jpegBytes))
	if err != nil {
		t.Fatalf("jpeg.DecodeConfig: %v", err)
	}
	if max(cfg.Width, cfg.Height) > opts.MaxLongSidePx {
		t.Fatalf("long side %d > cap %d", max(cfg.Width, cfg.Height), opts.MaxLongSidePx)
	}
}

func within(actual, expected int, tolerance float64) bool {
	delta := float64(actual - expected)
	if delta < 0 {
		delta = -delta
	}
	return delta <= float64(expected)*tolerance
}
