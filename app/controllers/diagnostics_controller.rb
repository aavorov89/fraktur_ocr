class DiagnosticsController < ApplicationController
  # Deliberately raises a 500 so we can verify BetterStack receives the error
  # in Logs (logtail-rails) and marks the span as errored in Telemetry.
  def boom
    raise "BetterStack monitoring test: intentional 500 (user_id=#{current_user&.id} at #{Time.current.iso8601})"
  end
end
