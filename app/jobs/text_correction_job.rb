require 'net/http'
require 'json'

# Runs the document's whole buffer (all recognized fragments, in click order)
# through GPT and stores the result in documents.corrected_text. Triggered
# only by the "Correct text" button.
class TextCorrectionJob < ApplicationJob
  MODEL = "gpt-4o".freeze

  queue_as :default

  retry_on StandardError, wait: :polynomially_longer, attempts: 3 do |job, error|
    document = Document.find_by(id: job.arguments.first)
    document&.update!(correction_status: :failed, correction_error: error.message) if document&.correction_processing?
  end

  def perform(document_id)
    document = Document.find(document_id)
    return unless document.correction_processing?

    text = document.recognized_text
    if text.blank?
      document.update!(correction_status: :failed, correction_error: "No recognized text to correct")
      return
    end

    api_key = Rails.application.credentials.dig(:openai, :api_key)
    if api_key.blank?
      document.update!(correction_status: :failed, correction_error: "OpenAI API key not configured")
      return
    end

    response = ActiveSupport::Notifications.instrument(
      "fraktur_ocr.correction",
      document_id: document.id,
      model:       MODEL
    ) do |payload|
      result = send_to_gpt4o(api_key, text)
      payload[:tokens_in]  = result[:tokens_in]
      payload[:tokens_out] = result[:tokens_out]
      payload[:status]     = result[:success] ? "success" : "error"
      result
    end

    # "Clear" (or a newer request after a stale one) may have happened while
    # GPT was working; a cleared buffer must stay empty.
    document.reload
    return unless document.correction_processing?

    if response[:success]
      document.update!(corrected_text: response[:text], correction_status: :completed, correction_error: nil)
    else
      document.update!(correction_status: :failed, correction_error: response[:error])
    end
  end

  private

  def send_to_gpt4o(api_key, text)
    uri = URI("https://api.openai.com/v1/chat/completions")

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 180

    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    request["Authorization"] = "Bearer #{api_key}"

    request.body = {
      model: MODEL,
      temperature: 0.3,
      messages: [
        {
          role: "system",
          content: <<~PROMPT
            You are tasked with correcting errors in OCR-transcribed text from an 18th-century German book originally printed in Fraktur typeface.

            The text was transcribed from image crops by an AI OCR system and may contain recognition errors.
            Consecutive crops are separated by blank lines; a word or sentence may continue from one crop into the next.

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
      choice = body.dig("choices", 0)
      # The whole buffer goes in one request; a truncated answer would
      # silently drop the tail of the text.
      if choice&.dig("finish_reason") == "length"
        return { success: false, error: "Text is too long for a single correction (the answer was cut off). Clear part of the buffer and try again." }
      end

      {
        success:    true,
        text:       choice&.dig("message", "content"),
        tokens_in:  body.dig("usage", "prompt_tokens"),
        tokens_out: body.dig("usage", "completion_tokens")
      }
    else
      error_msg = body.dig("error", "message") || "OpenAI API error: #{response.code}"
      { success: false, error: error_msg }
    end
  rescue Net::ReadTimeout
    { success: false, error: "OpenAI API request timed out." }
  rescue JSON::ParserError
    { success: false, error: "Invalid response from OpenAI API." }
  end
end
