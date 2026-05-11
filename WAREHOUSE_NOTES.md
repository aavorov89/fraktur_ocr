# Better Stack Warehouse integration notes

Observations and design decisions from wiring per-page OCR analytics into
this Rails 8.1 + Go renderer stack. Companion to the user-facing README
section.

## Single event per page, even under retry

The OCR pipeline is three ActiveJobs chained via `perform_later`
(`OcrJob` → `TextCorrectionJob` → `TranslationJob`), each declaring
`retry_on StandardError, attempts: 3`. The naive instinct is to put the
warehouse emit inside the same instrumentation block that measures stage
timing. That would push one event per *attempt*, corrupting aggregate
analytics: a single retry-then-succeed page would land as two rows.

The split adopted here:

- `ActiveSupport::Notifications.instrument("fraktur_ocr.<stage>")` wraps
  each external HTTP call. It fires on every attempt and is read by a
  single subscriber (`PipelineSubscriber`) that overwrites
  `ocr_requests.metrics[<stage>]` each time. Successive attempts naturally
  leave the *last* attempt's values in place, which is what the final
  emit consumes.
- The actual `Emitter.push` happens in exactly two places per page:
  - the success path at the end of `TranslationJob#perform`, calling
    `Pipeline.flush(id, status: :completed)`;
  - the **block form of `retry_on`** on each job, which fires only after
    all configured attempts have been exhausted - that is the correct
    Rails hook for "terminal failure". The block calls
    `Pipeline.flush(id, status: :failed, failure_stage: <this-job's-stage>, error_class: ...)`.

(Earlier drafts used `discard_on`; this is wrong - `discard_on` fires
immediately on a matching exception, not after retries have been
exhausted, and `discard_on` and `retry_on` are evaluated in declaration
order with first-match winning. The block form of `retry_on` is the only
clean way to express "after all retries are spent".)

## ocr_requests.metrics jsonb column

The pipeline crosses three job processes (and the Go renderer, via the
render callback). Cross-stage state therefore has to live somewhere
durable. Three options were considered:

- A new column on `ocr_requests` (chosen). Persistent, transactional with
  the same row, easy to query for ad-hoc debugging, no new dependency.
- `Solid Cache`. Avoids the migration but adds a TTL concern, and a cache
  miss between stages would silently drop measurements.
- In-process state in `PipelineSubscriber`. Loses everything across worker
  processes - unacceptable in production.

The column carries one key per stage (`render`, `ocr`, `correction`,
`translation`), each a small flat object of measurements. Cost is computed
at the time `record_stage` runs and stored alongside raw token counts, so
the final emit is a pure read.

## Render-side measurement requires extending the callback contract

Originally the `render_done` callback POST body was `{}`. To surface
`render_ms`, `pdf_page_count`, and `render_dpi`, the Go renderer was
extended to:

- measure wall-clock from job start to just before the callback POST
  with `time.Since(start)`;
- thread the PDF page count out of `render.PageBitmap` (it was already
  computed inside `rasterize` but not surfaced);
- POST the three values as a `RenderDoneBody` JSON object.

The Rails callback handler parses the body best-effort: missing fields
default to `nil`, a non-Hash JSON value is treated as empty, an unparseable
body is treated as empty. The existing "empty body still succeeds" contract
is preserved (tested explicitly), so an older Go build sending `{}` keeps
working.

## Failure isolation

Every entry point into the analytics path - the subscriber, `Pipeline`
helpers, `Emitter.push` / `flush_once` / `drain` / `send_batch` - has an
outer `rescue => e` that logs via `Rails.logger.warn` and swallows. The
warehouse pipeline can never raise into a job, a request handler, or a
worker. Tests cover the swallow path for the transport (HTTP) layer.

The buffer is bounded (`BETTERSTACK_WAREHOUSE_BUFFER_MAX`, default 1000)
and overflows drop the *oldest* events. The producer never blocks. A
`dropped` counter is exposed on the emitter for tests / observability.

## Cross-product UX observations

- **Where Warehouse lives in the BetterStack UI.** Warehouse is a
  separate product surface from Logs / Telemetry / Errors - not a tab
  inside one of them. Tokens for it are issued under a different
  "API token" section than the source-ingest tokens used by Logs. This is
  a bit surprising given the marketing positioning of "one platform";
  expect new users to spend a couple of minutes finding the right page.
- **Two endpoint families.** Ingest goes to `https://<source-host>`
  (Bearer auth, same shape as Logs). Querying goes to
  `https://<cluster>.betterstackdata.com` (Basic auth, plain-text SQL
  body). The saved-query API is a third URL pattern again
  (`/query/<secret>.json` - no auth). All three are documented but
  scattered across multiple docs pages.
- **Doc gaps.** The Anthropic-style `OPTIONS`/`HEAD` probing of the
  ingest endpoint isn't documented; the docs landing page at
  `betterstack.com/docs/logs/warehouse/` returned 404 during integration
  and we had to navigate via Google to find the actual content under
  `/docs/warehouse/...`. The `output_format_pretty_row_numbers=0` query
  parameter is required for the ad-hoc SQL endpoint but easy to miss.
- **No official Ruby SDK.** Net::HTTP suffices because the API surface
  is small (one POST shape) and the existing project pattern is plain
  Net::HTTP across all three external integrations.

## Design tradeoffs

- **`update_column` vs `update!`.** `record_stage` uses `update_column`
  to bypass validations and callbacks. The ocr_request has a Turbo Stream
  `broadcast_update_to` after-commit callback that fires on `update!` and
  would flood the channel with every stage write. The metrics column is
  not user-visible and its updates don't need to participate in the
  document's broadcast lifecycle.
- **DeepL char count = input text length, not response-reported.** DeepL's
  response doesn't include a "billed characters" field, so we use the
  input string length as the proxy. This matches DeepL's published billing
  semantics ("characters sent in API requests") but is technically a
  client-side estimate.
- **`Time.now - created_at` for `total_ms`.** Wallclock approximation
  including queue time. Strictly this includes any time the
  `ocr_request` sat waiting for the render slot or the next worker. That
  is *desirable* for end-to-end SLO analytics: it's the user-perceived
  latency. If you want OCR-only timing, sum the per-stage `*_ms` columns
  instead.

## Things that surprised me

- The block form of `retry_on` is the only first-class Rails idiom for
  "do X after all retries are exhausted". There is no built-in
  `on_final_failure` callback. Worth a flag in onboarding docs.
- ActiveSupport::Notifications subscribers already rescue subscriber
  errors by default. Belt-and-braces here (outer rescue in
  `PipelineSubscriber.handle`) but worth confirming if anyone is
  considering depending on that behavior.
- `Document.create!` plus `document.ocr_requests.create!` plus
  `update_column(:metrics, ...)` does not trigger the broadcast
  callbacks, but `update!(metrics: ...)` would, because the model has
  an `after_update_commit :broadcast_result`. That's a gotcha if anyone
  later changes `record_stage` to use the full update API.
- The Warehouse and Telemetry pricing tiers are interlinked
  (one token type covers both) but the UI presents them as
  independent products. Easy to confuse a Telemetry token with a
  Warehouse source-ingest token; they're different.
