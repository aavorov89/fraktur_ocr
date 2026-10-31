require 'net/http'
require 'json'

# Translates the document's corrected text (the raw buffer if it was never
# corrected) with DeepL into documents.translated_text. Triggered only by the
# "Translate" button.
class TranslationJob < ApplicationJob
  queue_as :default

  retry_on StandardError, wait: :polynomially_longer, attempts: 3 do |job, error|
    document = Document.find_by(id: job.arguments.first)
    document&.update!(translation_status: :failed, translation_error: error.message) if document&.translation_processing?
  end

  def perform(document_id)
    document = Document.find(document_id)
    return unless document.translation_processing?

    text_to_translate = document.corrected_text.presence || document.recognized_text
    if text_to_translate.blank?
      document.update!(translation_status: :failed, translation_error: "No text to translate")
      return
    end

    api_key = Rails.application.credentials.dig(:deepl, :api_key)
    api_host = Rails.application.credentials.dig(:deepl, :api_host)
    if api_key.blank? || api_host.blank?
      document.update!(translation_status: :failed, translation_error: "DeepL API credentials not configured")
      return
    end

    response = ActiveSupport::Notifications.instrument(
      "fraktur_ocr.translation",
      document_id: document.id,
      chars:       text_to_translate.length
    ) do |payload|
      result = send_to_deepl(api_key, api_host, text_to_translate, document.target_language)
      payload[:status] = result[:success] ? "success" : "error"
      result
    end

    # Dropped if the buffer was cleared meanwhile.
    document.reload
    return unless document.translation_processing?

    if response[:success]
      document.update!(translated_text: response[:text], translation_status: :completed, translation_error: nil)
    else
      document.update!(translation_status: :failed, translation_error: response[:error])
    end
  end

  private

  def send_to_deepl(api_key, api_host, text, target_lang)
    uri = URI("#{api_host}/v2/translate")

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 120

    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    request["Authorization"] = "DeepL-Auth-Key #{api_key}"

    request.body = {
      text: [text],
      source_lang: "DE",
      target_lang: target_lang
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
