class RenderEnqueuer
  KIND = "render_pdf_crop".freeze
  QUEUE = "default".freeze
  MAX_ATTEMPTS = 5
  PRIORITY = 1

  # Inserts a row directly into river's `river_job` table. The Go render
  # service consumes these. We bypass ActiveJob/Sidekiq entirely on the
  # render side; Rails only handles the post-render OcrJob via the listener.
  def self.enqueue(ocr_request)
    args = build_args(ocr_request)
    inject_trace_context!(args)

    ActiveRecord::Base.connection.exec_query(
      <<~SQL,
        INSERT INTO river_job (args, kind, queue, max_attempts, priority, state, scheduled_at, created_at)
        VALUES ($1::jsonb, $2, $3, $4, $5, 'available', now(), now())
        RETURNING id
      SQL
      "RenderEnqueuer",
      [args.to_json, KIND, QUEUE, MAX_ATTEMPTS, PRIORITY]
    )
  end

  def self.build_args(ocr_request)
    {
      ocr_request_id: ocr_request.id,
      pdf_path: "#{ocr_request.document_id}.pdf",
      page: ocr_request.page_number,
      rect_pts: {
        x: ocr_request.rect_x.to_f,
        y: ocr_request.rect_y.to_f,
        w: ocr_request.rect_w.to_f,
        h: ocr_request.rect_h.to_f
      }
    }
  end

  # Capture the active OTel trace context as a W3C carrier and embed it in
  # the job args so the Go renderer can continue the trace. No-op when OTel
  # isn't loaded (dev/test) or when there's no active span.
  def self.inject_trace_context!(args)
    return unless defined?(OpenTelemetry)

    carrier = {}
    OpenTelemetry.propagation.inject(carrier)
    args[:trace] = carrier if carrier.any?
  end
end
