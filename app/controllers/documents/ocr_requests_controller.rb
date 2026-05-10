module Documents
  class OcrRequestsController < ApplicationController
    def create
      @document = Document.find(params[:document_id])

      attrs = ocr_request_attributes
      return head(:unprocessable_entity) if attrs.nil?

      @ocr_request = @document.ocr_requests.new(attrs)

      unless @ocr_request.save
        return head(:unprocessable_entity)
      end

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

      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: [
            turbo_stream.update("ocr_panel",
              partial: "documents/ocr_panel",
              locals: { ocr_request: @ocr_request }),
            turbo_stream.update("translation_panel",
              partial: "documents/translation_panel",
              locals: { ocr_request: @ocr_request })
          ]
        end
      end
    end

    def update_language
      @document = Document.find(params[:document_id])
      @ocr_request = @document.ocr_requests.find(params[:id])

      if @ocr_request.update(target_language: params[:target_language])
        # Clear previous translation and re-trigger translation job
        @ocr_request.update(translated_text: nil, translation_error: nil)
        TranslationJob.perform_later(@ocr_request.id)

        respond_to do |format|
          format.turbo_stream do
            render turbo_stream: turbo_stream.update("translation_panel",
              partial: "documents/translation_panel",
              locals: { ocr_request: @ocr_request })
          end
        end
      else
        head :unprocessable_entity
      end
    end

    private

    def ocr_request_attributes
      raw = params.require(:ocr_request).permit(:page_number, :target_language, rect_pts: [:x, :y, :w, :h])
      base = { page_number: raw[:page_number], target_language: raw[:target_language] }.compact

      rect = raw[:rect_pts]
      if rect.is_a?(ActionController::Parameters) || rect.is_a?(Hash)
        base.merge(rect_x: rect[:x], rect_y: rect[:y], rect_w: rect[:w], rect_h: rect[:h])
      elsif params.dig(:ocr_request, :crop_data).present?
        # crop_data path: rect columns stay null, the JPEG already encodes the
        # cropped region.
        base
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
