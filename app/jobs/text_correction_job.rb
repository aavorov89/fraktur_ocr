require 'net/http'
require 'json'

class TextCorrectionJob < ApplicationJob
  queue_as :default

  retry_on StandardError, wait: :polynomially_longer, attempts: 3

  def perform(ocr_request_id)
    ocr_request = OcrRequest.find(ocr_request_id)

    # Skip if no text to correct
    if ocr_request.recognized_text.blank?
      TranslationJob.perform_later(ocr_request.id)
      return
    end

    api_key = Rails.application.credentials.dig(:openai, :api_key)

    if api_key.blank?
      # Store error and continue to translation
      ocr_request.update!(correction_error: "OpenAI API key not configured")
      TranslationJob.perform_later(ocr_request.id)
      return
    end

    response = send_to_gpt4o(api_key, ocr_request.recognized_text)

    if response[:success]
      ocr_request.update!(corrected_text: response[:text], correction_error: nil)
    else
      ocr_request.update!(correction_error: response[:error])
    end

    # Always chain translation job, even if correction failed
    TranslationJob.perform_later(ocr_request.id)
  rescue => e
    ocr_request = OcrRequest.find_by(id: ocr_request_id)
    ocr_request&.update(correction_error: e.message)
    # Continue to translation even on error
    TranslationJob.perform_later(ocr_request_id) if ocr_request
    raise # Re-raise for retry mechanism
  end

  private

  def send_to_gpt4o(api_key, text)
    uri = URI("https://api.openai.com/v1/chat/completions")

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 60

    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    request["Authorization"] = "Bearer #{api_key}"

    request.body = {
      model: "gpt-4o",
      temperature: 0.3,
      messages: [
        {
          role: "system",
          content: <<~PROMPT
            You are tasked with correcting errors in OCR-transcribed text from an 18th-century German book originally printed in Fraktur typeface.

            The text was transcribed from image crops by an AI OCR system and may contain recognition errors.

            Please follow these instructions:

            1. Reconnect words split across lines: if a word is broken with '-' or '=' at the end of a line, join the parts into a single word and remove the line break.
            2. The '/' symbol in the original text is used as a comma — replace all '/' with commas.
            3. Correct obvious OCR misreadings (e.g. confused characters like ſ/s/f, u/n, rn/m, cl/d) while preserving the intended 18th-century German spelling.
            4. Fix punctuation and capitalization errors introduced by OCR, but do not modernize the original style.
            5. Preserve the original paragraph structure.
            6. Do not translate, paraphrase, or alter the meaning of the text.
            7. Be conservative: when in doubt whether something is an OCR error or an authentic archaic form, keep the original.

            Return ONLY the corrected German text, nothing else.
          PROMPT
        },
        {
          role: "user",
          content: text
        }
      ]
    }.to_json

    response = http.request(request)
    body = JSON.parse(response.body)

    if response.code.to_i == 200
      corrected_text = body.dig("choices", 0, "message", "content")
      { success: true, text: corrected_text }
    else
      error_msg = body.dig("error", "message") || "OpenAI API error: #{response.code}"
      { success: false, error: error_msg }
    end
  rescue Net::ReadTimeout
    { success: false, error: "OpenAI API request timed out. Try a smaller selection." }
  rescue JSON::ParserError
    { success: false, error: "Invalid response from OpenAI API." }
  end
end
