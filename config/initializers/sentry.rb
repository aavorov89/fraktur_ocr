# Reports unhandled exceptions to BetterStack Errors via the Sentry-compatible
# DSN. Active only when SENTRY_DSN is set; dev/test boot the same as before.
#
# Required env vars in production:
#   SENTRY_DSN   the "DSN" value shown in BetterStack → Errors → Application
#
# Tracing is left to OpenTelemetry (config/initializers/opentelemetry.rb), so
# we set traces_sample_rate to 0 — Sentry only handles error capture here.

if ENV["SENTRY_DSN"].present?
  Sentry.init do |config|
    config.dsn = ENV["SENTRY_DSN"]
    config.environment = ENV.fetch("SENTRY_ENVIRONMENT", Rails.env)
    config.release = ENV["IMAGE_TAG"].presence || ENV["GIT_SHA"].presence

    # Strip noisy framework frames from grouped stack traces.
    config.app_dirs_pattern = %r{(app|lib|config)}

    # Don't ship sensitive request data. Rails filters params via
    # config.filter_parameters; mirror that here.
    config.send_default_pii = false

    # Skip the boom endpoint's noise during local dev — keeps the issue list
    # in BetterStack focused on real exceptions in production.
    config.excluded_exceptions += ["ActionController::RoutingError"]

    # OTel owns tracing — don't double-report spans through Sentry.
    config.traces_sample_rate = 0.0

    # ActiveJob retries: report on every failure attempt (default) so a flaky
    # OcrJob shows up in BetterStack with its full retry history.
  end
end
