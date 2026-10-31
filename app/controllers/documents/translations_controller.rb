module Documents
  # "Translate": sends the corrected text (raw buffer if there is none yet)
  # to DeepL (TranslationJob).
  class TranslationsController < ApplicationController
    def create
      @document = Document.find(params[:document_id])
      language = params[:target_language].presence || @document.target_language
      return head(:unprocessable_entity) unless Document::TARGET_LANGUAGES.include?(language)

      @document.with_lock do
        next if @document.translation_running?

        if @document.corrected_text.blank? && @document.recognized_text.blank?
          @document.update!(target_language: language, translation_status: :failed, translation_error: t("translation.empty_source"))
        else
          @document.update!(target_language: language, translation_status: :processing,
                            translation_error: nil, translation_requested_at: Time.current)
          TranslationJob.perform_later(@document.id)
        end
      end

      render turbo_stream: turbo_stream.update("translation_panel",
        partial: "documents/translation_panel", locals: { document: @document })
    end
  end
end
