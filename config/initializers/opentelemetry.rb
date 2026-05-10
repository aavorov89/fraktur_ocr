# Ship traces (Rails + ActiveRecord + ActiveJob + Net::HTTP) to BetterStack
# Telemetry via OTLP/HTTP. Active only when OTEL_EXPORTER_OTLP_ENDPOINT is
# set; dev/test boot the same as before.
#
# Required env vars in production:
#   OTEL_EXPORTER_OTLP_ENDPOINT  e.g. https://in-otel.logs.betterstack.com
#   OTEL_EXPORTER_OTLP_HEADERS   Authorization=Bearer <BETTERSTACK_TELEMETRY_TOKEN>
#   OTEL_SERVICE_NAME            defaults to "fraktur-rails"
#
# Trace propagation across the render pipeline:
#   Rails request → RenderEnqueuer injects W3C traceparent into the river
#   job args → Go renderer continues the trace → Go HTTP callback to Rails
#   carries the traceparent header → Rails auto-extracts on the inbound side.

if ENV["OTEL_EXPORTER_OTLP_ENDPOINT"].present?
  require "opentelemetry/sdk"
  require "opentelemetry/exporter/otlp"
  require "opentelemetry/instrumentation/all"

  OpenTelemetry::SDK.configure do |c|
    c.service_name = ENV.fetch("OTEL_SERVICE_NAME", "fraktur-rails")
    c.use_all
  end
end
