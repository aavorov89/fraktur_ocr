module Documents
  # A click on a detected text region: recognize it (no correction) and
  # append the text to the document's buffer. A region already in the buffer
  # is a no-op, except that a failed one is recognized again.
  class OcrRequestsController < ApplicationController
    def create
      @document = Document.find(params[:document_id])

      attrs = ocr_request_attributes
      return head(:unprocessable_entity) if attrs.nil?

      @ocr_request = @document.ocr_requests.buffered.find_or_initialize_by(attrs.slice(:page_number, :region_index))
      return render_buffer if @ocr_request.persisted? && !@ocr_request.failed?

      # A retried region keeps its place in the buffer.
      @ocr_request.assign_attributes(attrs.merge(status: :pending, error_message: nil, metrics: {}))
      return head(:unprocessable_entity) unless @ocr_request.save

      if (data_url = params.dig(:ocr_request, :crop_data)).present?
        # Browser-side path: the JS controller already rendered the page at
        # high DPI, cropped, and JPEG-encoded the bitmap. Skip the Go renderer
        # entirely — write the file to disk and run OcrJob directly.
        save_browser_crop(@ocr_request.id, data_url)
        OcrJob.perform_later(@ocr_request.id)
      else
        # Server-side path: enqueue a river job, the Go renderer writes the
        # JPEG and calls back into Internal::OcrRequestsController#render_done,
        # which then enqueues OcrJob.
        RenderEnqueuer.enqueue(@ocr_request)
      end

      render_buffer
    rescue ActiveRecord::RecordNotUnique
      # Double click raced past the lookup; the first request owns the region.
      render_buffer
    end

    private

    def render_buffer
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.update("recognized_panel",
            partial: "documents/recognized_panel", locals: { document: @document })
        end
      end
    end

    def ocr_request_attributes
      raw = params.require(:ocr_request).permit(:page_number, :region_index, rect_pts: [:x, :y, :w, :h])
      return nil if raw[:page_number].blank? || raw[:region_index].blank?

      base = { page_number: raw[:page_number].to_i, region_index: raw[:region_index].to_i }

      rect = raw[:rect_pts]
      if rect.is_a?(ActionController::Parameters) || rect.is_a?(Hash)
        base.merge(rect_x: rect[:x], rect_y: rect[:y], rect_w: rect[:w], rect_h: rect[:h])
      elsif params.dig(:ocr_request, :crop_data).present?
        # crop_data path: rect columns stay null, the JPEG already encodes the
        # cropped region.
        base.merge(rect_x: nil, rect_y: nil, rect_w: nil, rect_h: nil)
      else
        nil
      end
    end

    def save_browser_crop(id, data_url)
      base64 = data_url.sub(/\Adata:.*?;base64,/, "")
      bytes = Base64.strict_decode64(base64)
      dir = ENV.fetch("RENDER_OUTPUT_DIR")
      FileUtils.mkdir_p(dir)
      path = File.join(dir, "#{id}.jpg")
      tmp = "#{path}.tmp"
      File.binwrite(tmp, bytes)
      File.rename(tmp, path)
    end
  end
end
