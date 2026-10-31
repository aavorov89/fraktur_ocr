module Documents
  # "Correct text": runs the whole buffer through GPT (TextCorrectionJob).
  class CorrectionsController < ApplicationController
    def create
      @document = Document.find(params[:document_id])

      @document.with_lock do
        next if @document.correction_running?

        if @document.recognized_text.blank?
          @document.update!(correction_status: :failed, correction_error: t("correction.empty_buffer"))
        else
          @document.update!(correction_status: :processing, correction_error: nil, correction_requested_at: Time.current)
          TextCorrectionJob.perform_later(@document.id)
        end
      end

      render turbo_stream: turbo_stream.update("corrected_panel",
        partial: "documents/corrected_panel", locals: { document: @document })
    end
  end
end
