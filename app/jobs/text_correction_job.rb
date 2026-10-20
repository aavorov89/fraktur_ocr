require 'net/http'
require 'json'

# Runs the document's whole buffer (all recognized fragments, in click order)
# through GPT and stores the result in documents.corrected_text. Triggered
# only by the "Correct text" button.
#
# The buffer goes out in chunks of whole fragments: asked to correct a
# 47-page buffer in one request, gpt-5.2 silently dropped 41% of it (with
# finish_reason "stop"), so every chunk is also checked for lost words.
class TextCorrectionJob < ApplicationJob
  # On real buffers gpt-5.2 (no reasoning, the chat-completions default) kept
  # the 18th-century spelling that gpt-4o modernized; reasoning_effort
  # "medium" cost ~3.5x and modernized some words again.
  MODEL = "gpt-5.2".freeze
  # ~6 book pages per request; a chunk closes after a fragment that ends a
  # sentence once it reaches CHUNK_CHARS, or unconditionally at 1.5x.
  CHUNK_CHARS = 6_000
  PARALLEL_REQUESTS = 4
  # Correction joins hyphenated words and may fix a few, but must not lose
  # text: a chunk keeping fewer words than this is rejected.
  MIN_WORD_RATIO = 0.85

  queue_as :default

  retry_on StandardError, wait: :polynomially_longer, attempts: 3 do |job, error|
    document = Document.find_by(id: job.arguments.first)
    document&.update!(correction_status: :failed, correction_error: error.message) if document&.correction_processing?
  end

  def perform(document_id)
    document = Document.find(document_id)
    return unless document.correction_processing?

    fragments = document.buffered_ocr_requests.select(&:completed?).filter_map { _1.recognized_text.presence }
    if fragments.empty?
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
      result = correct_in_chunks(api_key, self.class.chunk_fragments(fragments))
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

  # Groups fragments (in buffer order) into request-sized texts, splitting
  # only between fragments and preferably after the end of a sentence.
  def self.chunk_fragments(fragments)
    chunks = [[]]
    size = 0
    fragments.each do |fragment|
      chunks.last << fragment
      size += fragment.size
      sentence_end = fragment.rstrip.match?(/[.!?:]\z/)
      next unless (size >= CHUNK_CHARS && sentence_end) || size >= CHUNK_CHARS * 1.5

      chunks << []
      size = 0
    end
    chunks.reject(&:empty?).map { _1.join("\n\n") }
  end

  # Final touches GPT applies only some of the time: paragraphs as single
  # lines, and the Fraktur double hyphen (OCR'd as "=" or "⸗") as a plain
  # "-" - "Hoch=Wohl= und Ehrw." -> "Hoch-Wohl- und Ehrw.". The recognized
  # text keeps the printed signs.
  def self.normalize(text)
    unwrap_lines(text.strip).tr("=⸗", "--")
  end

  # Paragraphs as single lines. GPT followed "remove the line breaks" in some
  # chunks and kept the print's lines in others; a line break after a hyphen
  # stays, since a compound hyphen ("Kirchen- und") can't be told from an
  # unjoined word here.
  def self.unwrap_lines(text)
    text.gsub(/(?<![-=⸗\n])[ \t]*\n(?!\n)[ \t]*/, " ")
  end

  # Words of a text with hyphenated line breaks joined, for the
  # lost-text check.
  def self.word_count(text)
    text.gsub(/[-=⸗]\s*\n\s*/, "").scan(/[[:alpha:]]+/).size
  end

  # Yields each JSON event of a server-sent-events body ("data: {...}" lines,
  # ending with "data: [DONE]"); chunks may split lines anywhere.
  def self.each_sse_event(response)
    pending = +""
    response.read_body do |chunk|
      pending << chunk
      while (newline = pending.index("\n"))
        line = pending.slice!(0..newline).strip
        next unless line.start_with?("data:")

        data = line.delete_prefix("data:").strip
        yield JSON.parse(data) unless data == "[DONE]"
      end
    end
  end

  private

  def correct_in_chunks(api_key, chunks)
    results = chunks.each_slice(PARALLEL_REQUESTS).flat_map do |batch|
      batch.map { |chunk| Thread.new { [chunk, send_to_openai(api_key, chunk)] } }.map(&:value)
    end

    tokens_in = results.sum { |_, r| r[:tokens_in].to_i }
    tokens_out = results.sum { |_, r| r[:tokens_out].to_i }
    failure = results.find { |_, r| !r[:success] }
    return failure[1].merge(tokens_in:, tokens_out:) if failure

    results.each_with_index do |(chunk, r), i|
      source, corrected = self.class.word_count(chunk), self.class.word_count(r[:text].to_s)
      next if corrected >= source * MIN_WORD_RATIO

      return { success: false, tokens_in:, tokens_out:,
               error: "The corrected text of part #{i + 1}/#{results.size} lost words (#{corrected} of #{source}); nothing was saved. Try again." }
    end

    { success: true, text: results.map { |_, r| self.class.normalize(r[:text]) }.join("\n\n"), tokens_in:, tokens_out: }
  end

  def send_to_openai(api_key, text)
    uri = URI("https://api.openai.com/v1/chat/completions")

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    # Streamed, so this bounds the gap between chunks, not the whole answer.
    http.read_timeout = 120

    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    request["Authorization"] = "Bearer #{api_key}"

    # Streamed: a whole-buffer correction runs for minutes, and a silent
    # non-streaming connection was cut after 60 s (EOFError) somewhere on the
    # network path.
    request.body = {
      model: MODEL,
      temperature: 0.3,
      stream: true,
      stream_options: { include_usage: true },
      messages: [
        {
          role: "system",
          content: <<~PROMPT
            You are tasked with correcting errors in OCR-transcribed text from an 18th-century German book originally printed in Fraktur typeface.

            The text was transcribed from image crops by an AI OCR system and may contain recognition errors.
            Consecutive crops are separated by blank lines; a word or sentence may continue from one crop into the next - join it.

            Please follow these instructions:

            1. Reconnect words split across lines: if a word is broken with '-', '=' or '⸗' at the end of a line, join the parts into a single word and remove the line break.
            2. The '/' symbol in the original text is used as a comma — replace all '/' with commas.
            3. Correct obvious OCR misreadings (e.g. confused characters like ſ/s/f, u/n, rn/m, cl/d) while preserving the intended 18th-century German spelling.
            4. Fix punctuation errors introduced by OCR, but do not modernize the original style. Keep the capitalization exactly as printed: in this book most nouns are lowercase - never capitalize a lowercase word.
            5. Remove the printed line breaks: write each paragraph as one continuous line, with a blank line between paragraphs. Keep the original paragraph division.
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

    text = +""
    finish_reason = nil
    usage = {}
    error_msg = nil

    http.request(request) do |response|
      if response.code.to_i != 200
        body = JSON.parse(response.read_body) rescue {}
        error_msg = body.dig("error", "message") || "OpenAI API error: #{response.code}"
        next
      end

      self.class.each_sse_event(response) do |event|
        choice = event.dig("choices", 0)
        text << choice.dig("delta", "content").to_s if choice
        finish_reason = choice["finish_reason"] if choice&.dig("finish_reason")
        usage = event["usage"] if event["usage"]
      end
    end

    return { success: false, error: error_msg } if error_msg
    # The whole buffer goes in one request; a truncated answer would
    # silently drop the tail of the text.
    if finish_reason == "length"
      return { success: false, error: "Text is too long for a single correction (the answer was cut off). Clear part of the buffer and try again." }
    end
    return { success: false, error: "OpenAI stream ended without an answer." } if finish_reason.nil?

    {
      success:    true,
      text:       text,
      tokens_in:  usage["prompt_tokens"],
      tokens_out: usage["completion_tokens"]
    }
  rescue Net::ReadTimeout
    { success: false, error: "OpenAI API request timed out." }
  rescue JSON::ParserError
    { success: false, error: "Invalid response from OpenAI API." }
  end
end
