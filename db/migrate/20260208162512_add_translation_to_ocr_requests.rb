class AddTranslationToOcrRequests < ActiveRecord::Migration[8.1]
  def change
    add_column :ocr_requests, :translated_text, :text
    add_column :ocr_requests, :translation_error, :text
  end
end
