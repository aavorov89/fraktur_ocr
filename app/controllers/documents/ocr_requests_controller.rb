module Documents
  class OcrRequestsController < ApplicationController
    def create
      @document = Document.find(params[:document_id])

      attrs = ocr_request_attributes
      return head(:unprocessable_entity) if attrs.nil?

      @ocr_request = @document.ocr_requests.new(attrs)

      if @ocr_request.save
        # Don't enqueue OcrJob here — the Go render service will write a JPEG
        # and NOTIFY render_done, and the listener daemon will enqueue OcrJob.
        RenderEnqueuer.enqueue(@ocr_request)

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
      else
        head :unprocessable_entity
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
      rect = raw[:rect_pts]
      return nil unless rect.is_a?(ActionController::Parameters) || rect.is_a?(Hash)

      {
        page_number: raw[:page_number],
        target_language: raw[:target_language],
        rect_x: rect[:x],
        rect_y: rect[:y],
        rect_w: rect[:w],
        rect_h: rect[:h]
      }.compact
    end
  end
end
