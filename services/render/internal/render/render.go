package render

import (
	"bytes"
	"context"
	"fmt"
	"image"
	"image/jpeg"
	"image/png"
	"os"

	"github.com/gen2brain/go-fitz"
	"golang.org/x/image/draw"

	"github.com/fraktur-ocr/services/render/internal/cache"
)

type Options struct {
	CanonicalDPI  float64
	MaxLongSidePx int
	JPEGQuality   int
}

// RectPts is a rectangle in PDF user-space points with origin at the TOP-LEFT
// of the page (PDF.js convention). The PDF spec's native origin is bottom-left,
// but MuPDF returns rasters with origin at top-left, so we never have to flip
// — points-with-top-left-origin map to rendered-pixel-with-top-left-origin
// just by scaling.
type RectPts struct {
	X, Y, W, H float64
}

// PageBitmap renders page (1-indexed) at opts.CanonicalDPI, using the disk
// cache. It returns a decoded RGBA image, the PDF's total page count
// (surfaced for analytics), and whether the bitmap came from the cache.
func PageBitmap(ctx context.Context, c *cache.Cache, pdfPath string, page int, opts Options) (image.Image, int, bool, error) {
	st, err := os.Stat(pdfPath)
	if err != nil {
		return nil, 0, false, fmt.Errorf("stat pdf: %w", err)
	}
	key := cache.Key(pdfPath, st.ModTime().Unix(), page, opts.CanonicalDPI)

	// page count requires opening the PDF; do it once up-front so both
	// cache-hit and cache-miss paths can surface it.
	pageCount, err := pdfPageCount(pdfPath)
	if err != nil {
		return nil, 0, false, err
	}

	if path, hit, err := c.Get(ctx, key); err != nil {
		return nil, pageCount, false, err
	} else if hit {
		img, err := readPNG(path)
		if err != nil {
			return nil, pageCount, false, fmt.Errorf("decode cached png: %w", err)
		}
		return img, pageCount, true, nil
	}

	img, pngBytes, err := rasterize(pdfPath, page, opts.CanonicalDPI, pageCount)
	if err != nil {
		return nil, pageCount, false, err
	}
	if _, err := c.Put(ctx, key, pngBytes); err != nil {
		return nil, pageCount, false, err
	}
	return img, pageCount, false, nil
}

func pdfPageCount(pdfPath string) (int, error) {
	doc, err := fitz.New(pdfPath)
	if err != nil {
		return 0, fmt.Errorf("open pdf: %w", err)
	}
	defer doc.Close()
	return doc.NumPage(), nil
}

func rasterize(pdfPath string, page int, dpi float64, pageCount int) (image.Image, []byte, error) {
	doc, err := fitz.New(pdfPath)
	if err != nil {
		return nil, nil, fmt.Errorf("open pdf: %w", err)
	}
	defer doc.Close()
	if page < 1 || page > pageCount {
		return nil, nil, fmt.Errorf("page %d out of range (1..%d)", page, pageCount)
	}
	// go-fitz uses 0-indexed pages.
	img, err := doc.ImageDPI(page-1, dpi)
	if err != nil {
		return nil, nil, fmt.Errorf("rasterize: %w", err)
	}
	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		return nil, nil, fmt.Errorf("encode png: %w", err)
	}
	return img, buf.Bytes(), nil
}

func readPNG(path string) (image.Image, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	return png.Decode(f)
}

// CropAndEncode crops rectPts (top-left origin, in points) out of pageImg,
// downsamples so the long side is ≤ opts.MaxLongSidePx, and JPEG-encodes at
// opts.JPEGQuality.
func CropAndEncode(pageImg image.Image, rectPts RectPts, opts Options) ([]byte, image.Rectangle, error) {
	pxPerPt := opts.CanonicalDPI / 72.0
	bounds := pageImg.Bounds()

	x0 := int(rectPts.X * pxPerPt)
	y0 := int(rectPts.Y * pxPerPt)
	x1 := int((rectPts.X + rectPts.W) * pxPerPt)
	y1 := int((rectPts.Y + rectPts.H) * pxPerPt)

	x0 = clamp(x0, bounds.Min.X, bounds.Max.X)
	y0 = clamp(y0, bounds.Min.Y, bounds.Max.Y)
	x1 = clamp(x1, bounds.Min.X, bounds.Max.X)
	y1 = clamp(y1, bounds.Min.Y, bounds.Max.Y)
	if x1 <= x0 || y1 <= y0 {
		return nil, image.Rectangle{}, fmt.Errorf("crop rect empty after clamp: pts=%+v image=%v", rectPts, bounds)
	}

	cropRect := image.Rect(x0, y0, x1, y1)
	cropped := image.NewRGBA(image.Rect(0, 0, cropRect.Dx(), cropRect.Dy()))
	draw.Copy(cropped, image.Point{}, pageImg, cropRect, draw.Src, nil)

	return downsampleAndEncode(cropped, opts)
}

// EncodePage downsamples a whole page bitmap so the long side is ≤
// opts.MaxLongSidePx and JPEG-encodes it. Used for text-region detection,
// which needs the full page rather than a crop.
func EncodePage(pageImg image.Image, opts Options) ([]byte, image.Rectangle, error) {
	return downsampleAndEncode(pageImg, opts)
}

func downsampleAndEncode(src image.Image, opts Options) ([]byte, image.Rectangle, error) {
	final := downsample(src, opts.MaxLongSidePx)

	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, final, &jpeg.Options{Quality: opts.JPEGQuality}); err != nil {
		return nil, image.Rectangle{}, fmt.Errorf("encode jpeg: %w", err)
	}
	return buf.Bytes(), final.Bounds(), nil
}

func downsample(src image.Image, maxLongSide int) image.Image {
	b := src.Bounds()
	w, h := b.Dx(), b.Dy()
	long := w
	if h > long {
		long = h
	}
	if long <= maxLongSide {
		return src
	}
	ratio := float64(maxLongSide) / float64(long)
	dw := int(float64(w) * ratio)
	dh := int(float64(h) * ratio)
	if dw < 1 {
		dw = 1
	}
	if dh < 1 {
		dh = 1
	}
	dst := image.NewRGBA(image.Rect(0, 0, dw, dh))
	draw.CatmullRom.Scale(dst, dst.Bounds(), src, b, draw.Over, nil)
	return dst
}

func clamp(v, lo, hi int) int {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}
