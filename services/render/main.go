package main

import (
	"context"
	"errors"
	"log/slog"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/riverqueue/river"
	"github.com/riverqueue/river/riverdriver/riverpgxv5"

	"github.com/fraktur-ocr/services/render/internal/cache"
	"github.com/fraktur-ocr/services/render/internal/config"
	"github.com/fraktur-ocr/services/render/internal/job"
	"github.com/fraktur-ocr/services/render/internal/render"
)

func main() {
	if err := run(); err != nil {
		slog.Error("fatal", "err", err.Error())
		os.Exit(1)
	}
}

func run() error {
	cfg, err := config.Load()
	if err != nil {
		return err
	}

	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: cfg.LogLevel}))
	slog.SetDefault(logger)

	if err := os.MkdirAll(cfg.RenderOutputDir, 0o755); err != nil {
		return err
	}

	cch, err := cache.Open(cfg.CacheDir, cfg.CacheMaxBytes)
	if err != nil {
		return err
	}
	defer cch.Close()

	rootCtx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	pool, err := pgxpool.New(rootCtx, cfg.DatabaseURL)
	if err != nil {
		return err
	}
	defer pool.Close()

	workers := river.NewWorkers()
	river.AddWorker(workers, &job.Worker{
		PDFRootDir:      cfg.PDFRootDir,
		RenderOutputDir: cfg.RenderOutputDir,
		Pool:            pool,
		Cache:           cch,
		Opts: render.Options{
			CanonicalDPI:  cfg.CanonicalDPI,
			MaxLongSidePx: cfg.MaxLongSidePx,
			JPEGQuality:   cfg.JPEGQuality,
		},
		Logger: logger,
	})

	client, err := river.NewClient(riverpgxv5.New(pool), &river.Config{
		Logger:  logger,
		Workers: workers,
		Queues: map[string]river.QueueConfig{
			river.QueueDefault: {MaxWorkers: cfg.WorkerConcurrency},
		},
	})
	if err != nil {
		return err
	}

	if err := client.Start(rootCtx); err != nil {
		return err
	}
	logger.Info("render service started",
		"queue", river.QueueDefault,
		"concurrency", cfg.WorkerConcurrency,
		"pdf_root", cfg.PDFRootDir,
		"output_dir", cfg.RenderOutputDir,
		"cache_dir", cfg.CacheDir,
	)

	<-rootCtx.Done()
	logger.Info("shutting down")

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if err := client.Stop(shutdownCtx); err != nil && !errors.Is(err, context.Canceled) {
		return err
	}
	return nil
}
