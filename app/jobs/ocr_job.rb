require 'net/http'
require 'json'
require 'base64'

class OcrJob < ApplicationJob
  MODEL = "claude-sonnet-4-20250514".freeze

  queue_as :default

  # Retry up to 3 times on any error; the block form fires only after the
  # configured attempts have been exhausted, which is the correct hook
  # point for emitting a single terminal-failure warehouse event.
  retry_on StandardError, wait: :polynomially_longer, attempts: 3 do |job, error|
    BetterStackWarehouse::Pipeline.flush(
      job.arguments.first,
      status:        :failed,
      failure_stage: :ocr,
      error_class:   error.class.name
    )
  end

  def perform(ocr_request_id)
    ocr_request = OcrRequest.find(ocr_request_id)
    jpeg_path = File.join(self.class.render_output_dir, "#{ocr_request_id}.jpg")

    # Buffer cleared before we got here: nobody will see the text.
    if ocr_request.cleared_at?
      File.delete(jpeg_path) rescue nil
      return
    end

    ocr_request.update!(status: :processing)
    raise "rendered crop not found at #{jpeg_path}" unless File.exist?(jpeg_path)

    api_key = Rails.application.credentials.dig(:anthropic, :api_key)
    raise "Anthropic API key not configured. Run: rails credentials:edit" if api_key.blank?

    image_bytes = File.binread(jpeg_path)
    base64_data = Base64.strict_encode64(image_bytes)

    response = ActiveSupport::Notifications.instrument(
      "fraktur_ocr.ocr",
      ocr_request_id:   ocr_request.id,
      model:            MODEL,
      image_size_bytes: image_bytes.bytesize
    ) do |payload|
      result = send_to_claude(api_key, base64_data, "image/jpeg")
      payload[:tokens_in]  = result[:tokens_in]
      payload[:tokens_out] = result[:tokens_out]
      payload[:status]     = result[:success] ? "success" : "error"
      result
    end

    if response[:success]
      # Correction and translation run later over the whole buffer, on demand.
      ocr_request.update!(status: :completed, recognized_text: response[:text])
      File.delete(jpeg_path) rescue nil
      BetterStackWarehouse::Pipeline.flush(ocr_request.id, status: :completed)
    else
      ocr_request.update!(status: :failed, error_message: response[:error])
    end
  rescue => e
    ocr_request = OcrRequest.find_by(id: ocr_request_id)
    ocr_request&.update(status: :failed, error_message: e.message)
    raise # Re-raise for retry mechanism
  end

  def self.render_output_dir
    ENV.fetch("RENDER_OUTPUT_DIR", "/var/lib/fraktur/crops")
  end

  private

  def send_to_claude(api_key, base64_data, media_type)
    uri = URI("https://api.anthropic.com/v1/messages")

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 60

    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    request["x-api-key"] = api_key
    request["anthropic-version"] = "2023-06-01"

    request.body = {
      model: MODEL,
      max_tokens: 4096,
      messages: [
        {
          role: "user",
          content: [
            {
              type: "image",
              source: {
                type: "base64",
                media_type: media_type,
                data: base64_data
              }
            },
            {
              type: "text",
              text: <<~PROMPT
                You are tasked with recognizing and transcribing text from an 18th-century German book printed in Fraktur (German Gothic) typeface.

                1. Carefully examine the image and transcribe all visible German text, converting Fraktur to modern Latin script.
                2. Preserve the original text exactly as it appears — including line breaks, hyphenation, punctuation, and any archaic spellings.
                3. Do NOT clean up, modernize, or correct the text in any way. Transcribe faithfully.
                4. If you encounter illegible or uncertain characters, represent them with [?].
                5. Do not describe images, decorative elements, or add any commentary.
                6. Output ONLY the raw transcription, nothing else.
              PROMPT
            }
          ]
        }
      ]
    }.to_json

    response = http.request(request)
    body = JSON.parse(response.body)

    if response.code.to_i == 200
      text = body["content"]
        &.select { |block| block["type"] == "text" }
        &.map { |block| block["text"] }
        &.join("\n")

      {
        success:    true,
        text:       text,
        tokens_in:  body.dig("usage", "input_tokens"),
        tokens_out: body.dig("usage", "output_tokens")
      }
    else
      error_msg = body.dig("error", "message") || "API error: #{response.code}"
      { success: false, error: error_msg }
    end
  rescue Net::ReadTimeout
    { success: false, error: "Claude API request timed out. Try a smaller selection." }
  rescue JSON::ParserError
    { success: false, error: "Invalid response from Claude API." }
  end
end
