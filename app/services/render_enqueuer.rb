class RenderEnqueuer
  KIND = "render_pdf_crop".freeze
  QUEUE = "default".freeze
  MAX_ATTEMPTS = 5
  PRIORITY = 1

  # Whole-page renders for text-region detection. Priority 2 (river: 1 is
  # highest) so crops for a region the user just clicked go first.
  PAGE_KIND = "render_pdf_page".freeze
  PAGE_MAX_ATTEMPTS = 3
  PAGE_PRIORITY = 2

  # Inserts a row directly into river's `river_job` table. The Go render
  # service consumes these. We bypass ActiveJob/Sidekiq entirely on the
  # render side; Rails only handles the post-render OcrJob via the listener.
  def self.enqueue(ocr_request)
    insert(build_args(ocr_request), KIND, MAX_ATTEMPTS, PRIORITY)
  end

  # The Go renderer writes the page JPEG and calls back into
  # Internal::PageLayoutsController#render_done, which runs
  # LayoutDetectionJob.
  def self.enqueue_page(page_layout)
    args = {
      page_layout_id: page_layout.id,
      pdf_path: "#{page_layout.document_id}.pdf",
      page: page_layout.page_number
    }
    insert(args, PAGE_KIND, PAGE_MAX_ATTEMPTS, PAGE_PRIORITY)
  end

  def self.insert(args, kind, max_attempts, priority)
    inject_trace_context!(args)

    ActiveRecord::Base.connection.exec_query(
      <<~SQL,
        INSERT INTO river_job (args, kind, queue, max_attempts, priority, state, scheduled_at, created_at)
        VALUES ($1::jsonb, $2, $3, $4, $5, 'available', now(), now())
        RETURNING id
      SQL
      "RenderEnqueuer",
      [args.to_json, kind, QUEUE, max_attempts, priority]
    )
  end
  private_class_method :insert

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
