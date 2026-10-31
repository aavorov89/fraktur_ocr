module BetterStackWarehouse
  # Single subscriber for all fraktur_ocr.<stage> ActiveSupport::Notifications
  # events. Computes cost from token / character counts via Pricing and
  # persists the stage snapshot into ocr_requests.metrics. The terminal
  # emit to BetterStack is performed separately by Pipeline.flush, called
  # from the jobs' success or final-failure paths.
  module PipelineSubscriber
    EVENT_PREFIX = "fraktur_ocr."

    def self.attach!
      # Resolve the module on every event: in development a code reload
      # replaces it, and the stale copy captured here can no longer see
      # Pipeline / Pricing.
      ActiveSupport::Notifications.subscribe(/^#{Regexp.escape(EVENT_PREFIX)}/) do |name, started, finished, _id, payload|
        ::BetterStackWarehouse::PipelineSubscriber.handle(name, started, finished, payload)
      end
    end

    def self.handle(name, started, finished, payload)
      stage = name.sub(EVENT_PREFIX, "").to_sym
      block_ms = ((finished - started) * 1000).to_i
      ocr_request_id = payload[:ocr_request_id]

      case stage
      when :render
        # Timing for the render stage comes from inside the Go service via
        # the callback body, not from this instrument block (which fires
        # synchronously in the Rails callback handler and would only
        # measure parse time). Fall back to block_ms only if missing.
        Pipeline.record_stage(:render,
          ocr_request_id: ocr_request_id,
          ms:             payload[:render_ms] || block_ms,
          pdf_page_count: payload[:pdf_page_count],
          render_dpi:     payload[:render_dpi]
        )
      when :ocr
        tokens_in  = payload[:tokens_in]
        tokens_out = payload[:tokens_out]
        Pipeline.record_stage(:ocr,
          ocr_request_id:   ocr_request_id,
          ms:               block_ms,
          model:            payload[:model],
          tokens_in:        tokens_in,
          tokens_out:       tokens_out,
          cost_usd:         tokens_in && tokens_out ? Pricing.tokens(payload[:model], tokens_in: tokens_in, tokens_out: tokens_out) : nil,
          image_size_bytes: payload[:image_size_bytes],
          status:           payload[:status]&.to_s
        )
      when :correction
        tokens_in  = payload[:tokens_in]
        tokens_out = payload[:tokens_out]
        Pipeline.record_stage(:correction,
          ocr_request_id: ocr_request_id,
          ms:             block_ms,
          model:          payload[:model],
          tokens_in:      tokens_in,
          tokens_out:     tokens_out,
          cost_usd:       tokens_in && tokens_out ? Pricing.tokens(payload[:model], tokens_in: tokens_in, tokens_out: tokens_out) : nil,
          status:         payload[:status]&.to_s
        )
      when :translation
        chars = payload[:chars]
        Pipeline.record_stage(:translation,
          ocr_request_id: ocr_request_id,
          ms:             block_ms,
          chars:          chars,
          cost_usd:       chars ? Pricing.deepl(chars: chars) : nil,
          status:         payload[:status]&.to_s
        )
      end
    rescue => e
      Rails.logger.warn("[BetterStackWarehouse] subscriber error on #{name}: #{e.class}: #{e.message}")
    end
  end
end
