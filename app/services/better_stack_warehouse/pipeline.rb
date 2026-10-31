module BetterStackWarehouse
  # Aggregates per-stage metrics in ocr_requests.metrics and emits exactly
  # one warehouse event per page when the pipeline reaches a terminal
  # outcome (completed at the end of OcrJob, or failed after OcrJob's
  # retry_on attempts are exhausted). Correction and translation run over a
  # whole document's buffer, so they no longer belong to one page's event.
  module Pipeline
    STAGES = %i[render ocr correction translation].freeze

    # Persist the latest snapshot of one stage's metrics into
    # ocr_requests.metrics. Called by PipelineSubscriber on every
    # fraktur_ocr.<stage> notification (including retries); the column ends
    # up holding the values from the most recent attempt, which is fine
    # because Pipeline.flush is gated on terminal outcome.
    def self.record_stage(stage, ocr_request_id:, **payload)
      return unless ocr_request_id
      ocr_request = OcrRequest.find_by(id: ocr_request_id)
      return unless ocr_request

      stage_key = stage.to_s
      compact   = payload.transform_keys(&:to_s).compact
      metrics   = (ocr_request.metrics || {}).deep_dup
      metrics[stage_key] = (metrics[stage_key] || {}).merge(compact)

      ocr_request.update_column(:metrics, metrics)
    rescue => e
      Rails.logger.warn("[BetterStackWarehouse] record_stage(#{stage}) failed: #{e.class}: #{e.message}")
    end

    # Build and enqueue a single warehouse event. Called from:
    #   - OcrJob success path (status: :completed)
    #   - OcrJob's retry_on block (status: :failed)
    def self.flush(ocr_request_id, status:, failure_stage: nil, error_class: nil)
      return unless ocr_request_id
      ocr_request = OcrRequest.find_by(id: ocr_request_id)
      return unless ocr_request
      ocr_request.reload

      event = build_event(ocr_request,
                          status: status,
                          failure_stage: failure_stage,
                          error_class: error_class)
      BetterStackWarehouse.emitter&.push(event)
    rescue => e
      Rails.logger.warn("[BetterStackWarehouse] flush failed: #{e.class}: #{e.message}")
    end

    def self.build_event(ocr_request, status:, failure_stage:, error_class:)
      m            = ocr_request.metrics || {}
      render_m     = m["render"]      || {}
      ocr_m        = m["ocr"]         || {}
      correction_m = m["correction"]  || {}
      translation_m = m["translation"] || {}

      pipeline_path = render_m.present? ? "server" : "browser"

      {
        ts:                    Time.now.utc.iso8601(3),
        ocr_request_id:        ocr_request.id,
        doc_id:                ocr_request.document_id,
        page_num:              ocr_request.page_number,
        source_format:         "pdf",
        pipeline_path:         pipeline_path,
        image_size_bytes:      ocr_m["image_size_bytes"],
        render_ms:             render_m["ms"],
        pdf_page_count:        render_m["pdf_page_count"],
        render_dpi:            render_m["render_dpi"],
        ocr_provider:          "anthropic",
        ocr_model:             ocr_m["model"],
        ocr_ms:                ocr_m["ms"],
        ocr_tokens_in:         ocr_m["tokens_in"],
        ocr_tokens_out:        ocr_m["tokens_out"],
        ocr_cost_usd:          ocr_m["cost_usd"],
        ocr_chars:             ocr_request.recognized_text&.length,
        correction_provider:   "openai",
        correction_model:      correction_m["model"],
        correction_ms:         correction_m["ms"],
        correction_tokens_in:  correction_m["tokens_in"],
        correction_tokens_out: correction_m["tokens_out"],
        correction_cost_usd:   correction_m["cost_usd"],
        correction_chars:      ocr_request.corrected_text&.length,
        translation_provider:  "deepl",
        translation_ms:        translation_m["ms"],
        translation_chars:     translation_m["chars"],
        translation_cost_usd:  translation_m["cost_usd"],
        target_language:       ocr_request.target_language,
        total_ms:              ((Time.now - ocr_request.created_at) * 1000).to_i,
        status:                status.to_s,
        failure_stage:         failure_stage&.to_s,
        error_class:           error_class
      }
    end
  end
end
