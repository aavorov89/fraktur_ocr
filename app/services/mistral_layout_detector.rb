require "net/http"
require "json"
require "base64"

# Finds the text regions on a single rendered page image using Mistral OCR's
# paragraph-level blocks. Only the block geometry is kept — the actual
# recognition still goes through the Claude pipeline (OcrJob) once the user
# clicks a region.
class MistralLayoutDetector
  MODEL = "mistral-ocr-latest".freeze
  ENDPOINT = URI("https://api.mistral.ai/v1/ocr").freeze

  # Block types that never contain recognizable text.
  SKIPPED_BLOCK_TYPES = %w[image].freeze

  class Error < StandardError; end

  # Returns { regions: [{ "x", "y", "w", "h", "type" }, ...], model: "..." }
  # with coordinates normalized to 0..1 of the page image.
  def self.detect(image_bytes, media_type)
    api_key = Rails.application.credentials.dig(:mistral, :api_key)
    raise Error, "Mistral API key not configured. Run: rails credentials:edit" if api_key.blank?

    body = request_ocr(api_key, image_bytes, media_type)
    page = body["pages"]&.first
    raise Error, "Mistral OCR returned no pages" if page.nil?

    { regions: regions_from_page(page), model: body["model"] || MODEL }
  end

  def self.regions_from_page(page)
    width = page.dig("dimensions", "width").to_f
    height = page.dig("dimensions", "height").to_f
    raise Error, "Mistral OCR returned no page dimensions" unless width.positive? && height.positive?

    Array(page["blocks"]).filter_map do |block|
      next if SKIPPED_BLOCK_TYPES.include?(block["type"])

      x1 = (block["top_left_x"].to_f / width).clamp(0.0, 1.0)
      y1 = (block["top_left_y"].to_f / height).clamp(0.0, 1.0)
      x2 = (block["bottom_right_x"].to_f / width).clamp(0.0, 1.0)
      y2 = (block["bottom_right_y"].to_f / height).clamp(0.0, 1.0)
      next if x2 <= x1 || y2 <= y1

      { "x" => x1.round(5), "y" => y1.round(5), "w" => (x2 - x1).round(5), "h" => (y2 - y1).round(5),
        "type" => block["type"] }
    end
  end

  def self.request_ocr(api_key, image_bytes, media_type)
    http = Net::HTTP.new(ENDPOINT.host, ENDPOINT.port)
    http.use_ssl = true
    http.read_timeout = 60

    request = Net::HTTP::Post.new(ENDPOINT)
    request["Content-Type"] = "application/json"
    request["Authorization"] = "Bearer #{api_key}"
    request.body = {
      model: MODEL,
      document: {
        type: "image_url",
        image_url: "data:#{media_type};base64,#{Base64.strict_encode64(image_bytes)}"
      },
      include_blocks: true,
      include_image_base64: false
    }.to_json

    response = http.request(request)
    body = JSON.parse(response.body)
    return body if response.code.to_i == 200

    message = body["message"] || body.dig("error", "message") || body["detail"]
    message = message.to_json unless message.nil? || message.is_a?(String)
    raise Error, message || "Mistral API error: #{response.code}"
  rescue Net::ReadTimeout
    raise Error, "Mistral OCR request timed out"
  rescue JSON::ParserError
    raise Error, "Invalid response from Mistral OCR"
  end
end
