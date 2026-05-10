// Tiny helper for manual testing — enqueues a single render_pdf_crop job.
//
//	go run ./cmd/enqueue \
//	  -ocr=42 -pdf=foo.pdf -page=1 -x=72 -y=72 -w=200 -h=100
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/riverqueue/river"
	"github.com/riverqueue/river/riverdriver/riverpgxv5"

	"github.com/fraktur-ocr/services/render/internal/job"
)

func main() {
	var (
		ocrID   int64
		pdfPath string
		page    int
		x, y    float64
		w, h    float64
	)
	flag.Int64Var(&ocrID, "ocr", 0, "OCR request ID")
	flag.StringVar(&pdfPath, "pdf", "", "PDF path relative to PDF_ROOT_DIR")
	flag.IntVar(&page, "page", 1, "Page number (1-indexed)")
	flag.Float64Var(&x, "x", 0, "Rect X in pt (top-left origin)")
	flag.Float64Var(&y, "y", 0, "Rect Y in pt (top-left origin)")
	flag.Float64Var(&w, "w", 100, "Rect width in pt")
	flag.Float64Var(&h, "h", 100, "Rect height in pt")
	flag.Parse()

	if ocrID == 0 || pdfPath == "" {
		fmt.Fprintln(os.Stderr, "ocr and pdf are required")
		flag.Usage()
		os.Exit(2)
	}

	dbURL := os.Getenv("DATABASE_URL")
	if dbURL == "" {
		log.Fatal("DATABASE_URL is required")
	}

	ctx := context.Background()
	pool, err := pgxpool.New(ctx, dbURL)
	if err != nil {
		log.Fatal(err)
	}
	defer pool.Close()

	client, err := river.NewClient(riverpgxv5.New(pool), &river.Config{})
	if err != nil {
		log.Fatal(err)
	}

	res, err := client.Insert(ctx, job.RenderArgs{
		OCRRequestID: ocrID,
		PDFPath:      pdfPath,
		Page:         page,
		RectPts:      job.RectPts{X: x, Y: y, W: w, H: h},
	}, nil)
	if err != nil {
		log.Fatal(err)
	}
	fmt.Printf("inserted river job id=%d kind=%s\n", res.Job.ID, res.Job.Kind)
}
