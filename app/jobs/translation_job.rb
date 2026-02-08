require 'net/http'
require 'json'

class TranslationJob < ApplicationJob
  queue_as :default

  retry_on StandardError, wait: :polynomially_longer, attempts: 3

  def perform(ocr_request_id)
    ocr_request = OcrRequest.find(ocr_request_id)

    # Skip if no text to translate
    return if ocr_request.recognized_text.blank?

    api_key = Rails.application.credentials.dig(:deepl, :api_key)
    api_host = Rails.application.credentials.dig(:deepl, :api_host)

    raise "DeepL API credentials not configured. Run: rails credentials:edit" if api_key.blank? || api_host.blank?

    response = send_to_deepl(api_key, api_host, ocr_request.recognized_text)

    if response[:success]
      ocr_request.update!(translated_text: response[:text])
    else
      ocr_request.update!(translation_error: response[:error])
    end
  rescue => e
    ocr_request = OcrRequest.find_by(id: ocr_request_id)
    ocr_request&.update(translation_error: e.message)
    raise # Re-raise for retry mechanism
  end

  private

  def send_to_deepl(api_key, api_host, text)
    uri = URI("#{api_host}/v2/translate")

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 60

    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    request["Authorization"] = "DeepL-Auth-Key #{api_key}"

    request.body = {
      text: [text],
      source_lang: "DE",
      target_lang: "EN"
    }.to_json

    response = http.request(request)
    body = JSON.parse(response.body)

    if response.code.to_i == 200
      translated_text = body.dig("translations", 0, "text")
      { success: true, text: translated_text }
    else
      error_msg = body.dig("message") || "DeepL API error: #{response.code}"
      { success: false, error: error_msg }
    end
  rescue Net::ReadTimeout
    { success: false, error: "DeepL API request timed out. Try again later." }
  rescue JSON::ParserError
    { success: false, error: "Invalid response from DeepL API." }
  end
end
