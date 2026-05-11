# README

This README would normally document whatever steps are necessary to get the
application up and running.

Things you may want to cover:

* Ruby version

* System dependencies

* Configuration

* Database creation

* Database initialization

* How to run the test suite

* Services (job queues, cache servers, search engines, etc.)

* Deployment instructions

* ...

## Better Stack Warehouse analytics

Per-page OCR processing analytics ship to a Better Stack Warehouse source
in addition to the existing Logs / Telemetry / Errors integrations. Exactly
one event is emitted per `ocr_request`, at the pipeline's terminal outcome
(after the DeepL translation succeeds, or after all retries are exhausted
in any stage). Cost-at-emission is recorded so historical aggregates
reflect the rate the operator was actually charged; raw token / character
counts are emitted alongside so future analyses can re-price.

### What is emitted

One JSON object per page with the following fields. Stages that did not
run on a given page (e.g. on a terminal failure) are emitted as `null`.

| Field | Type | Notes |
| --- | --- | --- |
| `ts` | string | ISO8601 emit time |
| `ocr_request_id` | int | 1:1 with `ocr_requests.id` |
| `doc_id` | int | `documents.id` |
| `page_num` | int | 1-indexed PDF page |
| `source_format` | string | always `"pdf"` |
| `pipeline_path` | string | `"server"` (Go renderer) or `"browser"` (JS crop fallback) |
| `image_size_bytes` | int | size of the JPEG sent to Claude |
| `render_ms` | int\|null | measured inside the Go renderer; null on browser path |
| `pdf_page_count` | int\|null | total pages in the source PDF |
| `render_dpi` | int\|null | canonical DPI used by the Go renderer |
| `ocr_provider` | string | `"anthropic"` |
| `ocr_model` | string | e.g. `"claude-sonnet-4-20250514"` |
| `ocr_ms` | int | wall-clock around the Claude HTTP call |
| `ocr_tokens_in` / `ocr_tokens_out` | int | from `usage` |
| `ocr_cost_usd` | float | priced at the rates in `Pricing` at emit time |
| `ocr_chars` | int | length of recognized text |
| `correction_provider` / `correction_model` | string | `"openai"` / `"gpt-4o"` |
| `correction_ms` | int | |
| `correction_tokens_in` / `correction_tokens_out` | int | |
| `correction_cost_usd` | float | |
| `correction_chars` | int | length of corrected text |
| `translation_provider` | string | `"deepl"` |
| `translation_ms` | int | |
| `translation_chars` | int | input length (DeepL bills per char) |
| `translation_cost_usd` | float | see DeepL pricing note below |
| `target_language` | string | `"RU"`, `"EN"`, ... |
| `total_ms` | int | from `ocr_request.created_at` to emit time |
| `status` | string | `"completed"` or `"failed"` |
| `failure_stage` | string\|null | `"ocr"`, `"correction"`, `"translation"` on failure |
| `error_class` | string\|null | Ruby class of the terminating exception |

**DeepL pricing note.** The DeepL per-character rate hard-coded in
`app/services/better_stack_warehouse/pricing.rb` (`DEEPL_PER_MCHAR`) is a
TODO placeholder; the DeepL Help Center pricing page was not directly
reachable during integration and secondary sources gave conflicting
numbers. Verify against the DeepL billing portal for your account before
relying on `translation_cost_usd` for budgeting. The Claude Sonnet 4 and
GPT-4o rates are confirmed against the providers' public pricing pages
(2026-05-11).

### Configuration

Configured exclusively via environment variables (matching the existing
Logs / Telemetry / Errors initializers). See `.env.example`. The
integration is a no-op unless both required values are present, and is
unconditionally disabled in `RAILS_ENV=test`.

```
BETTERSTACK_WAREHOUSE_INGEST_URL=https://in.logs.betterstack.com  # source-specific
BETTERSTACK_WAREHOUSE_SOURCE_TOKEN=...
BETTERSTACK_WAREHOUSE_BATCH_SIZE=50           # optional
BETTERSTACK_WAREHOUSE_FLUSH_INTERVAL_SECONDS=5 # optional
BETTERSTACK_WAREHOUSE_BUFFER_MAX=1000          # optional
```

The buffer is bounded; on overflow the *oldest* events are dropped so the
producer never blocks. All emitter exceptions are caught and logged via
`Rails.logger.warn`; the analytics path can never crash a job or a
request.

### Example SQL queries

ClickHouse SQL via the Warehouse ad-hoc API. Replace `t123456_fraktur_ocr_events` with
the source table name shown in the Warehouse UI. All queries below assume
the emitted JSON is materialized into typed columns by the source schema.

```sql
-- 1. p95 total_ms by ocr_provider, last 7 days.
SELECT
  ocr_provider,
  quantile(0.95)(total_ms) AS p95_total_ms,
  count() AS pages
FROM remote(t123456_fraktur_ocr_events)
WHERE dt >= now() - INTERVAL 7 DAY
GROUP BY ocr_provider
ORDER BY p95_total_ms DESC
FORMAT JSONEachRow;

-- 2. Daily spend by provider and stage. ocr/correction/translation are stacked.
SELECT
  toDate(dt) AS day,
  sumIf(ocr_cost_usd, ocr_cost_usd IS NOT NULL)                AS ocr_usd,
  sumIf(correction_cost_usd, correction_cost_usd IS NOT NULL)  AS correction_usd,
  sumIf(translation_cost_usd, translation_cost_usd IS NOT NULL) AS translation_usd,
  ocr_usd + correction_usd + translation_usd                   AS total_usd
FROM remote(t123456_fraktur_ocr_events)
WHERE dt >= now() - INTERVAL 30 DAY
GROUP BY day
ORDER BY day
FORMAT JSONEachRow;

-- 3. Correlation of recognized-text length vs image size bucket.
SELECT
  floor(image_size_bytes / 50000) * 50000 AS bytes_bucket,
  avg(ocr_chars)  AS avg_chars,
  count()         AS pages
FROM remote(t123456_fraktur_ocr_events)
WHERE dt >= now() - INTERVAL 30 DAY
  AND status = 'completed'
GROUP BY bytes_bucket
ORDER BY bytes_bucket
FORMAT JSONEachRow;

-- 4. 10 slowest pages in the last 24h with full stage breakdown.
SELECT
  ocr_request_id, doc_id, page_num,
  render_ms, ocr_ms, correction_ms, translation_ms, total_ms,
  ocr_provider, status, failure_stage
FROM remote(t123456_fraktur_ocr_events)
WHERE dt >= now() - INTERVAL 1 DAY
ORDER BY total_ms DESC
LIMIT 10
FORMAT JSONEachRow;

-- 5. Daily processing volume by pipeline_path (server vs browser-crop).
SELECT
  toDate(dt) AS day,
  pipeline_path,
  count()                  AS pages,
  countIf(status='failed') AS failures
FROM remote(t123456_fraktur_ocr_events)
WHERE dt >= now() - INTERVAL 14 DAY
GROUP BY day, pipeline_path
ORDER BY day, pipeline_path
FORMAT JSONEachRow;
```

### Saved query as API

Better Stack Warehouse can publish any saved query as a public read API
URL (no auth header; secret is in the URL). To wire the frontend straight
to live cost data without round-tripping through Rails, save query #2
above as a saved query named "Daily spend by provider" in the Warehouse
UI; the resulting URL is shaped like:

```
https://<cluster>.betterstackdata.com/query/<secret>.json
```

The frontend (or any caller) then fetches it as plain JSON, no auth
header needed:

```bash
curl "https://eu-nbg-2-connect.betterstackdata.com/query/abc123def.json"
# => [{"day":"2026-05-04","ocr_usd":1.23,"correction_usd":0.41,...}, ...]
```

Saved queries can take parameters via `{{name}}` placeholders in the SQL;
the API URL accepts them as query string args, e.g.
`?days=7`. See `WAREHOUSE_NOTES.md` for further integration observations.
