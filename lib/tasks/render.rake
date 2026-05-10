require "net/http"

namespace :render do
  desc "Delete orphaned JPEG crops older than 24h"
  task cleanup_orphans: :environment do
    dir = ENV.fetch("RENDER_OUTPUT_DIR")
    cutoff = 24.hours.ago
    deleted = 0
    Dir.glob(File.join(dir, "*.jpg")).each do |f|
      if File.mtime(f) < cutoff
        File.delete(f)
        deleted += 1
      end
    end
    Rails.logger.info("[render:cleanup_orphans] deleted #{deleted} orphan JPEG(s) older than 24h")

    # BetterStack heartbeat: ping when the job completes successfully. Failure
    # to reach BetterStack does not fail the task — the heartbeat is observability,
    # not a hard dependency.
    if (url = ENV["HEARTBEAT_URL_CLEANUP"]).present?
      begin
        Net::HTTP.get(URI(url))
      rescue => e
        Rails.logger.warn("[render:cleanup_orphans] heartbeat ping failed: #{e.message}")
      end
    end
  end
end
