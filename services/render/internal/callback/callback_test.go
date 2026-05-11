package callback

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestRenderDoneSuccess(t *testing.T) {
	var hits int32
	var gotPath, gotMethod, gotAuth, gotContentType string
	var gotBody []byte

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&hits, 1)
		gotPath = r.URL.Path
		gotMethod = r.Method
		gotAuth = r.Header.Get("X-Internal-Auth")
		gotContentType = r.Header.Get("Content-Type")
		gotBody, _ = io.ReadAll(r.Body)
		w.WriteHeader(http.StatusNoContent)
	}))
	defer srv.Close()

	c := NewClient(srv.URL, "s3cret", 2*time.Second)
	body := RenderDoneBody{RenderMs: 123, PDFPageCount: 7, RenderDPI: 300}
	if err := c.RenderDone(context.Background(), 42, body); err != nil {
		t.Fatalf("RenderDone returned error: %v", err)
	}

	if atomic.LoadInt32(&hits) != 1 {
		t.Fatalf("expected 1 hit, got %d", hits)
	}
	if gotMethod != http.MethodPost {
		t.Errorf("method = %q, want POST", gotMethod)
	}
	if gotPath != "/internal/ocr_requests/42/render_done" {
		t.Errorf("path = %q, want /internal/ocr_requests/42/render_done", gotPath)
	}
	if gotAuth != "s3cret" {
		t.Errorf("X-Internal-Auth = %q, want s3cret", gotAuth)
	}
	if gotContentType != "application/json" {
		t.Errorf("Content-Type = %q, want application/json", gotContentType)
	}

	var decoded map[string]int
	if err := json.Unmarshal(gotBody, &decoded); err != nil {
		t.Fatalf("body is not valid JSON object: %v (body=%q)", err, string(gotBody))
	}
	if decoded["render_ms"] != 123 {
		t.Errorf("render_ms = %d, want 123", decoded["render_ms"])
	}
	if decoded["pdf_page_count"] != 7 {
		t.Errorf("pdf_page_count = %d, want 7", decoded["pdf_page_count"])
	}
	if decoded["render_dpi"] != 300 {
		t.Errorf("render_dpi = %d, want 300", decoded["render_dpi"])
	}
}

func TestRenderDoneNon2xx(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer srv.Close()

	c := NewClient(srv.URL, "s3cret", 2*time.Second)
	err := c.RenderDone(context.Background(), 7, RenderDoneBody{})
	if err == nil {
		t.Fatal("expected error for 500 response, got nil")
	}
	if !strings.Contains(err.Error(), "500") {
		t.Errorf("error %q does not mention status code 500", err.Error())
	}
}

func TestRenderDoneTimeout(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(200 * time.Millisecond)
		w.WriteHeader(http.StatusNoContent)
	}))
	defer srv.Close()

	c := NewClient(srv.URL, "s3cret", 1*time.Millisecond)
	err := c.RenderDone(context.Background(), 1, RenderDoneBody{})
	if err == nil {
		t.Fatal("expected timeout error, got nil")
	}
}
