module Documents
  class OcrRequestsController < ApplicationController
    def create
      @document = Document.find(params[:document_id])
      @ocr_request = @document.ocr_requests.new(ocr_request_params)

      if @ocr_request.save
        OcrJob.perform_later(@ocr_request.id)

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

    def ocr_request_params
      params.require(:ocr_request).permit(:page_number, :crop_data, :target_language)
    end
  end
end
