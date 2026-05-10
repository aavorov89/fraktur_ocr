namespace :render do
  desc "Delete orphaned JPEG crops older than 24h"
  task cleanup_orphans: :environment do
    dir = ENV.fetch("RENDER_OUTPUT_DIR")
    cutoff = 24.hours.ago
    Dir.glob(File.join(dir, "*.jpg")).each do |f|
      File.delete(f) if File.mtime(f) < cutoff
    end
  end
end
