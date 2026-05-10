package config

import (
	"errors"
	"fmt"
	"log/slog"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"
)

type Config struct {
	DatabaseURL        string
	PDFRootDir         string
	RenderOutputDir    string
	CacheDir           string
	CacheMaxBytes      int64
	CanonicalDPI       float64
	MaxLongSidePx      int
	JPEGQuality        int
	WorkerConcurrency  int
	RailsBaseURL       string
	InternalAuthSecret string
	CallbackTimeout    time.Duration
	LogLevel           slog.Level
}

func Load() (*Config, error) {
	c := &Config{
		DatabaseURL:        os.Getenv("DATABASE_URL"),
		PDFRootDir:         os.Getenv("PDF_ROOT_DIR"),
		RenderOutputDir:    getEnv("RENDER_OUTPUT_DIR", "/var/lib/fraktur/crops"),
		CacheDir:           getEnv("CACHE_DIR", "/var/lib/fraktur/render-cache"),
		RailsBaseURL:       os.Getenv("RAILS_BASE_URL"),
		InternalAuthSecret: os.Getenv("INTERNAL_AUTH_SECRET"),
	}

	if c.DatabaseURL == "" {
		return nil, errors.New("DATABASE_URL is required")
	}
	if c.PDFRootDir == "" {
		return nil, errors.New("PDF_ROOT_DIR is required")
	}
	if c.RailsBaseURL == "" {
		return nil, errors.New("RAILS_BASE_URL is required")
	}
	if u, err := url.Parse(c.RailsBaseURL); err != nil || u.Scheme == "" || u.Host == "" {
		return nil, fmt.Errorf("RAILS_BASE_URL is not a valid URL: %q", c.RailsBaseURL)
	}
	if c.InternalAuthSecret == "" {
		return nil, errors.New("INTERNAL_AUTH_SECRET is required")
	}

	var err error
	if c.CacheMaxBytes, err = getEnvInt64("CACHE_MAX_BYTES", 2*1024*1024*1024); err != nil {
		return nil, err
	}
	if c.CanonicalDPI, err = getEnvFloat("CANONICAL_DPI", 300); err != nil {
		return nil, err
	}
	if c.MaxLongSidePx, err = getEnvInt("MAX_LONG_SIDE_PX", 2000); err != nil {
		return nil, err
	}
	if c.JPEGQuality, err = getEnvInt("JPEG_QUALITY", 92); err != nil {
		return nil, err
	}
	if c.WorkerConcurrency, err = getEnvInt("WORKER_CONCURRENCY", 2); err != nil {
		return nil, err
	}
	if c.CallbackTimeout, err = getEnvDuration("CALLBACK_TIMEOUT", 5*time.Second); err != nil {
		return nil, err
	}
	c.LogLevel = parseLogLevel(getEnv("LOG_LEVEL", "info"))

	if c.CacheMaxBytes <= 0 {
		return nil, errors.New("CACHE_MAX_BYTES must be > 0")
	}
	if c.CanonicalDPI <= 0 {
		return nil, errors.New("CANONICAL_DPI must be > 0")
	}
	if c.MaxLongSidePx <= 0 {
		return nil, errors.New("MAX_LONG_SIDE_PX must be > 0")
	}
	if c.JPEGQuality < 1 || c.JPEGQuality > 100 {
		return nil, errors.New("JPEG_QUALITY must be in [1,100]")
	}
	if c.WorkerConcurrency < 1 {
		return nil, errors.New("WORKER_CONCURRENCY must be >= 1")
	}
	if c.CallbackTimeout <= 0 {
		return nil, errors.New("CALLBACK_TIMEOUT must be > 0")
	}
	return c, nil
}

func getEnvDuration(key string, def time.Duration) (time.Duration, error) {
	v := os.Getenv(key)
	if v == "" {
		return def, nil
	}
	d, err := time.ParseDuration(v)
	if err != nil {
		return 0, fmt.Errorf("%s: %w", key, err)
	}
	return d, nil
}

func getEnv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func getEnvInt(key string, def int) (int, error) {
	v := os.Getenv(key)
	if v == "" {
		return def, nil
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		return 0, fmt.Errorf("%s: %w", key, err)
	}
	return n, nil
}

func getEnvInt64(key string, def int64) (int64, error) {
	v := os.Getenv(key)
	if v == "" {
		return def, nil
	}
	n, err := strconv.ParseInt(v, 10, 64)
	if err != nil {
		return 0, fmt.Errorf("%s: %w", key, err)
	}
	return n, nil
}

func getEnvFloat(key string, def float64) (float64, error) {
	v := os.Getenv(key)
	if v == "" {
		return def, nil
	}
	f, err := strconv.ParseFloat(v, 64)
	if err != nil {
		return 0, fmt.Errorf("%s: %w", key, err)
	}
	return f, nil
}

func parseLogLevel(s string) slog.Level {
	switch strings.ToLower(s) {
	case "debug":
		return slog.LevelDebug
	case "warn", "warning":
		return slog.LevelWarn
	case "error":
		return slog.LevelError
	default:
		return slog.LevelInfo
	}
}
