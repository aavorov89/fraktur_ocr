# Sends a page JPEG rendered by the Go service (render_pdf_page) to Mistral
# OCR and stores the detected text regions on the PageLayout.
class LayoutDetectionJob < ApplicationJob
  queue_as :default

  # Network hiccups get retried; once attempts run out the page is marked
  # failed so the viewer can show it and a later visit can request it again.
  retry_on StandardError, wait: :polynomially_longer, attempts: 3 do |job, error|
    PageLayout.find_by(id: job.arguments.first)&.update(status: :failed, error_message: error.message)
  end

  # API-level errors (bad key, quota, rejected image) won't fix themselves.
  discard_on MistralLayoutDetector::Error do |job, error|
    PageLayout.find_by(id: job.arguments.first)&.update(status: :failed, error_message: error.message)
  end

  def perform(page_layout_id)
    page_layout = PageLayout.find_by(id: page_layout_id)
    return if page_layout.nil? || page_layout.completed?

    jpeg_path = self.class.page_image_path(page_layout_id)
    raise "rendered page not found at #{jpeg_path}" unless File.exist?(jpeg_path)

    result = MistralLayoutDetector.detect(File.binread(jpeg_path), "image/jpeg")
    page_layout.update!(status: :completed, regions: result[:regions], model: result[:model], error_message: nil)
    File.delete(jpeg_path) rescue nil
  end

  # Matches job.PageOutputName in services/render.
  def self.page_image_path(page_layout_id)
    File.join(OcrJob.render_output_dir, "page-#{page_layout_id}.jpg")
  end
end
