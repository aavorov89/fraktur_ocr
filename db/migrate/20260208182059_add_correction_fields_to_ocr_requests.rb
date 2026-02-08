class AddCorrectionFieldsToOcrRequests < ActiveRecord::Migration[8.1]
  def change
    add_column :ocr_requests, :corrected_text, :text
    add_column :ocr_requests, :correction_error, :text
  end
end
