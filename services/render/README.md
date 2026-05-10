# services/render

A Go worker that renders PDF crops at a fixed high DPI (default 300) so that
downstream OCR (Claude Vision) sees Fraktur text at full fidelity rather than
at the user's display zoom. The service is a
[`river`](https://github.com/riverqueue/river) consumer of the
`render_pdf_crop` job kind. When a job finishes it writes a JPEG to disk and
then `POST`s `/internal/ocr_requests/<ocr_request_id>/render_done` on the
Rails app (header-auth via `X-Internal-Auth: $INTERNAL_AUTH_SECRET`) so Rails
can pick the crop up and forward it to Claude Vision.

## Configuration

| Var                  | Required | Default                          | Purpose                                            |
|----------------------|----------|----------------------------------|----------------------------------------------------|
| `DATABASE_URL`       | yes      | —                                | Postgres URL — same DB Rails uses                  |
| `PDF_ROOT_DIR`       | yes      | —                                | Root for resolving relative PDF paths              |
| `RENDER_OUTPUT_DIR`  | no       | `/var/lib/fraktur/crops`         | Where JPEG output is written                       |
| `CACHE_DIR`          | no       | `/var/lib/fraktur/render-cache`  | Disk-LRU location                                  |
| `CACHE_MAX_BYTES`    | no       | `2147483648` (2 GB)              | Cache size cap                                     |
| `CANONICAL_DPI`      | no       | `300`                            | DPI for cached page bitmaps                        |
| `MAX_LONG_SIDE_PX`   | no       | `2000`                           | Output crop long-side cap                          |
| `JPEG_QUALITY`       | no       | `92`                             | Output JPEG quality                                |
| `WORKER_CONCURRENCY` | no       | `2`                              | Concurrent river workers                           |
| `RAILS_BASE_URL`     | yes      | —                                | Base URL Rails is reachable at (e.g. `http://web:80`) |
| `INTERNAL_AUTH_SECRET` | yes    | —                                | Shared secret sent as `X-Internal-Auth` to Rails   |
| `CALLBACK_TIMEOUT`   | no       | `5s`                             | HTTP timeout for the Rails callback                |
| `LOG_LEVEL`          | no       | `info`                           | `debug`, `info`, `warn`, or `error`                |

## Job payload

```json
{
  "ocr_request_id": 42,
  "pdf_path": "uploads/2026-05-10/manuscript.pdf",
  "page": 3,
  "rect_pts": { "x": 72.0, "y": 144.0, "w": 360.0, "h": 240.0 }
}
```

Coordinate convention: origin at the **top-left** of the page (PDF.js style).
Units are PDF points (72 / inch). The PDF spec's native origin is bottom-left,
but MuPDF returns rasters with origin at top-left, so no flip is necessary —
the worker just multiplies points by `CANONICAL_DPI / 72`.

`pdf_path` is joined with `PDF_ROOT_DIR` and validated to refuse `..`
traversal. Bad paths and missing files are returned as `river.JobCancel`
(no retry).

## Quickstart (local)

The service does **not** run river migrations — Rails owns the schema. To run
locally against an empty Postgres you need to apply the river migrations once
yourself, e.g. via the [`river` CLI](https://github.com/riverqueue/river/tree/master/cmd/river):

```sh
# 1. Start Postgres.
docker run -d --name fraktur-pg -p 5432:5432 \
  -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=fraktur postgres:16

export DATABASE_URL=postgres://postgres:postgres@127.0.0.1:5432/fraktur

# 2. Apply river migrations (one-time, normally Rails does this).
go install github.com/riverqueue/river/cmd/river@latest
river migrate-up --database-url "$DATABASE_URL"

# 3. Prepare directories and a PDF.
mkdir -p /tmp/fraktur/{pdfs,crops,cache}
cp some.pdf /tmp/fraktur/pdfs/

# 4. From another shell, start a stub HTTP server to receive the callback.
#    `nc` will print the request and exit on first connection — for repeated
#    runs use a tiny Go stub instead.
nc -l 3000

# 5. Run the worker (point RAILS_BASE_URL at the stub above).
PDF_ROOT_DIR=/tmp/fraktur/pdfs \
RENDER_OUTPUT_DIR=/tmp/fraktur/crops \
CACHE_DIR=/tmp/fraktur/cache \
RAILS_BASE_URL=http://127.0.0.1:3000 \
INTERNAL_AUTH_SECRET=local-dev-secret \
go run .

# 6. Enqueue a job.
DATABASE_URL=$DATABASE_URL go run ./cmd/enqueue \
  -ocr=1 -pdf=some.pdf -page=1 -x=0 -y=0 -w=400 -h=200

# 7. Crop should land at /tmp/fraktur/crops/1.jpg, and the `nc` session
# should show:   POST /internal/ocr_requests/1/render_done HTTP/1.1
#                X-Internal-Auth: local-dev-secret
```

If you'd rather skip `cmd/enqueue`, you can shove a row directly into
`river_job` from `psql`:

```sql
INSERT INTO river_job (state, kind, queue, priority, args, max_attempts)
VALUES ('available', 'render_pdf_crop', 'default', 1,
        '{"ocr_request_id": 1, "pdf_path": "some.pdf", "page": 1,
          "rect_pts": {"x": 0, "y": 0, "w": 400, "h": 200}}'::jsonb,
        5);
```

## Tests

```sh
go test ./...
```

The render test builds a tiny in-memory PDF fixture (no checked-in binary)
and asserts the produced JPEG is decodable, has dimensions within ~5% of the
expected `pt → px` conversion, and respects `MAX_LONG_SIDE_PX`.

The cache test inserts entries totalling more than the cap, touches one to
keep it warm, then verifies the LRU eviction reduces total size below the cap
and the most-recently-accessed entry survives.

`// TODO: integration test` — A full Postgres + river round-trip is out of
scope for unit tests. To exercise it manually, follow the Quickstart above.

## Notes

- **River migrations are run by Rails**, not this service. We just connect to
  the existing tables.
- The service knows nothing about the `ocr_requests` table — it only touches
  river's tables and the Rails `/internal/*` callback endpoint.
- The path resolver could later be swapped for an `Storage` interface that
  reads from S3/MinIO, but it intentionally is **not** abstracted yet (YAGNI).
- Output is written `<ocr_request_id>.jpg.tmp` then `os.Rename`d into place
  so Rails never observes a half-written file.
- Cache layout: `<CACHE_DIR>/<sha256>.png` per cached page bitmap, with a
  `<CACHE_DIR>/index.db` SQLite file (pure-Go `modernc.org/sqlite`) tracking
  size and last-access. Eviction runs on every insert if the total exceeds
  `CACHE_MAX_BYTES`.
