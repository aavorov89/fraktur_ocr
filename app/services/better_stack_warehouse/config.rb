module BetterStackWarehouse
  # Reads BetterStack Warehouse configuration from ENV. Follows the same
  # env-gated pattern used by Logs (LOGTAIL_SOURCE_TOKEN), Telemetry
  # (OTEL_EXPORTER_OTLP_ENDPOINT) and Errors (SENTRY_DSN) elsewhere in this
  # project: when the required vars are absent the integration is a no-op.
  class Config
    DEFAULT_BATCH_SIZE      = 50
    DEFAULT_FLUSH_INTERVAL  = 5
    DEFAULT_BUFFER_MAX      = 1000

    attr_reader :ingest_url, :source_token, :batch_size,
                :flush_interval_seconds, :buffer_max

    def self.from_env(env: ENV, rails_env: Rails.env)
      new(
        ingest_url:             env["BETTERSTACK_WAREHOUSE_INGEST_URL"],
        source_token:           env["BETTERSTACK_WAREHOUSE_SOURCE_TOKEN"],
        batch_size:             Integer(env["BETTERSTACK_WAREHOUSE_BATCH_SIZE"] || DEFAULT_BATCH_SIZE),
        flush_interval_seconds: Integer(env["BETTERSTACK_WAREHOUSE_FLUSH_INTERVAL_SECONDS"] || DEFAULT_FLUSH_INTERVAL),
        buffer_max:             Integer(env["BETTERSTACK_WAREHOUSE_BUFFER_MAX"] || DEFAULT_BUFFER_MAX),
        rails_env:              rails_env
      )
    end

    def initialize(ingest_url:, source_token:, batch_size:, flush_interval_seconds:, buffer_max:, rails_env:)
      @ingest_url             = ingest_url.to_s.strip.presence
      @source_token           = source_token.to_s.strip.presence
      @batch_size             = batch_size
      @flush_interval_seconds = flush_interval_seconds
      @buffer_max             = buffer_max
      @rails_env              = rails_env.to_s
    end

    def enabled?
      return false if @rails_env == "test"
      @ingest_url.present? && @source_token.present?
    end
  end
end
