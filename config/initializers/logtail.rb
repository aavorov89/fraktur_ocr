# Ship Rails logs to BetterStack Logs (formerly Logtail) when a source token
# is configured. No-op in dev/test where the token is usually unset, so local
# work keeps logging to stdout / log/development.log as before.
if ENV["LOGTAIL_SOURCE_TOKEN"].present?
  http_device = Logtail::LogDevices::HTTP.new(
    ENV["LOGTAIL_SOURCE_TOKEN"],
    ingesting_host: ENV.fetch("LOGTAIL_INGEST_HOST", "in.logs.betterstack.com")
  )

  # Tee to both BetterStack and stdout so `docker logs` still works.
  Rails.logger = Logtail::Logger.new(http_device, $stdout)
end
