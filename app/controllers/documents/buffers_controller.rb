module Documents
  # "Clear": empties the recognized/corrected/translated panels and lets
  # already-recognized regions be clicked again.
  class BuffersController < ApplicationController
    def destroy
      @document = Document.find(params[:document_id])
      @document.clear_buffer!

      render turbo_stream: %i[recognized corrected translation].map { |name|
        turbo_stream.update("#{name}_panel", partial: "documents/#{name}_panel", locals: { document: @document })
      }
    end
  end
end
