package callback

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/propagation"
)

type Client struct {
	BaseURL string
	Secret  string
	HTTP    *http.Client
}

// RenderDoneBody is the JSON payload sent to Rails after a successful
// render. Rails persists these into ocr_requests.metrics for the
// BetterStack Warehouse analytics pipeline. Fields are advisory: a Rails
// build older than this contract will tolerate any subset, and an
// older Go build sending `{}` remains a valid callback.
type RenderDoneBody struct {
	RenderMs     int `json:"render_ms"`
	PDFPageCount int `json:"pdf_page_count"`
	RenderDPI    int `json:"render_dpi"`
}

func NewClient(baseURL, secret string, timeout time.Duration) *Client {
	return &Client{
		BaseURL: baseURL,
		Secret:  secret,
		HTTP:    &http.Client{Timeout: timeout},
	}
}

func (c *Client) RenderDone(ctx context.Context, ocrRequestID int64, body RenderDoneBody) error {
	u, err := url.JoinPath(c.BaseURL, "/internal/ocr_requests", strconv.FormatInt(ocrRequestID, 10), "/render_done")
	if err != nil {
		return fmt.Errorf("build callback URL: %w", err)
	}

	payload, err := json.Marshal(body)
	if err != nil {
		return fmt.Errorf("marshal callback body: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, u, bytes.NewReader(payload))
	if err != nil {
		return fmt.Errorf("build callback request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Internal-Auth", c.Secret)

	// Carry the current trace into Rails so the inbound /internal/* request
	// continues the same trace.
	otel.GetTextMapPropagator().Inject(ctx, propagation.HeaderCarrier(req.Header))

	resp, err := c.HTTP.Do(req)
	if err != nil {
		return fmt.Errorf("callback POST: %w", err)
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, resp.Body)

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("callback returned status %d", resp.StatusCode)
	}
	return nil
}
