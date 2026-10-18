module Documents
  # Text regions of a single PDF page, detected once per page by Mistral OCR
  # and cached in page_layouts. Clicking a region later starts the regular
  # OCR pipeline.
  #
  # Two ways to get the page image, mirroring OCR crops:
  # - browser path (PDF not on the server yet): the request carries a page
  #   JPEG rendered by pdf.js and detection runs synchronously;
  # - server path: the Go renderer renders the page (render_pdf_page), then
  #   LayoutDetectionJob calls Mistral and the result is broadcast.
  class TextRegionsController < ApplicationController
    MAX_IMAGE_BYTES = 15.megabytes
    DATA_URL = %r{\Adata:(image/(?:jpeg|png));base64,(.+)\z}m

    before_action :set_document

    def show
      layout = @document.page_layouts.find_by(page_number: params[:page_number])
      return head(:not_found) if layout.nil?

      render json: layout
    end

    def create
      page_number = params[:page_number].to_i
      return head(:unprocessable_entity) unless page_number.positive?

      # Idempotent: already detected, or a render is in flight (other tab,
      # prefetch).
      layout = @document.page_layouts.find_by(page_number: page_number)
      return render_layout(layout) if layout && !layout.detection_needed?

      if params[:image].present?
        detect_from_browser_image(page_number)
      elsif @document.pdf_stored?
        enqueue_server_render(page_number)
      else
        head :conflict
      end
    end

    private

    def set_document
      @document = Document.find(params[:document_id])
    end

    def detect_from_browser_image(page_number)
      match = DATA_URL.match(params[:image].to_s)
      return head(:unprocessable_entity) if match.nil?

      image_bytes = Base64.decode64(match[2])
      return head(:payload_too_large) if image_bytes.bytesize > MAX_IMAGE_BYTES

      result = MistralLayoutDetector.detect(image_bytes, match[1])
      layout = @document.page_layouts.create_or_find_by!(page_number: page_number)
      layout.update!(status: :completed, regions: result[:regions], model: result[:model], error_message: nil)
      render_layout(layout)
    rescue MistralLayoutDetector::Error => e
      Rails.logger.warn "Text region detection failed for document #{@document.id} page #{page_number}: #{e.message}"
      render json: { error: e.message }, status: :bad_gateway
    end

    def enqueue_server_render(page_number)
      layout = @document.page_layouts.create_or_find_by!(page_number: page_number)
      created = layout.previously_new_record?

      # Row lock so two tabs asking for a failed/stale page enqueue one render.
      layout.with_lock do
        if created || layout.detection_needed?
          # Explicit updated_at restarts the staleness clock even when the
          # row is already pending (a stale render).
          layout.update!(status: :pending, error_message: nil, updated_at: Time.current) unless created
          RenderEnqueuer.enqueue_page(layout)
        end
      end

      render_layout(layout)
    end

    def render_layout(layout)
      render json: layout, status: layout.pending? ? :accepted : :ok
    end
  end
end
