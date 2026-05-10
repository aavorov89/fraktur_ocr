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

  # Drops AR query spans coming from the Solid* polling tables (solid_cable
  # polls Postgres every 100 ms; solid_queue and solid_cache do similar work).
  # Those spans are useless noise but would bury the actual request traces
  # and burn the BetterStack quota.
  class SolidNoiseFilterSampler
    EXCLUDE_PREFIXES = %w[SolidCable:: SolidQueue:: SolidCache::].freeze
    DROP = OpenTelemetry::SDK::Trace::Samplers::Result.new(
      decision: OpenTelemetry::SDK::Trace::Samplers::Decision::DROP
    )

    def initialize(delegate)
      @delegate = delegate
    end

    def should_sample?(trace_id:, parent_context:, links:, name:, kind:, attributes:)
      return DROP if EXCLUDE_PREFIXES.any? { |p| name.start_with?(p) }
      @delegate.should_sample?(
        trace_id: trace_id, parent_context: parent_context, links: links,
        name: name, kind: kind, attributes: attributes
      )
    end

    def description
      "SolidNoiseFilter(#{@delegate.description})"
    end
  end

  OpenTelemetry::SDK.configure do |c|
    c.service_name = ENV.fetch("OTEL_SERVICE_NAME", "fraktur-rails")
    c.use_all
  end

  OpenTelemetry.tracer_provider.sampler =
    SolidNoiseFilterSampler.new(OpenTelemetry.tracer_provider.sampler)
end
