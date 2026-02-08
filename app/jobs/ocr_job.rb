class OcrJob < ApplicationJob
  queue_as :default

  retry_on StandardError, wait: :polynomially_longer, attempts: 3

  def perform(ocr_request_id)
    ocr_request = OcrRequest.find(ocr_request_id)
    ocr_request.update!(status: :processing)

    # Extract base64 data and media type from data URL
    data_url = ocr_request.crop_data
    media_type = data_url[/data:(.*?);/, 1] || "image/png"
    base64_data = data_url.sub(/\Adata:.*?;base64,/, "")

    api_key = Rails.application.credentials.dig(:anthropic, :api_key)
    raise "Anthropic API key not configured. Run: rails credentials:edit" if api_key.blank?

    response = send_to_claude(api_key, base64_data, media_type)

    if response[:success]
      ocr_request.update!(
        status: :completed,
        recognized_text: response[:text]
      )
    else
      ocr_request.update!(
        status: :failed,
        error_message: response[:error]
      )
    end
  rescue => e
    ocr_request = OcrRequest.find_by(id: ocr_request_id)
    ocr_request&.update(status: :failed, error_message: e.message)
    raise # Re-raise for retry mechanism
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
      model: "claude-sonnet-4-20250514",
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
                This is a scan of a German book printed in Fraktur (German Gothic) typeface.
                Please perform OCR on this image:
                1. Transcribe all German text you can see, converting from Fraktur to modern Latin script.
                2. Clean up the text: remove hyphenation at line breaks, join split words, fix obvious OCR artifacts.
                3. Keep the original German text, paragraphs, and punctuation intact.
                4. Output ONLY the clean German text, nothing else — no commentary, no labels, no markdown.
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

      { success: true, text: text }
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
