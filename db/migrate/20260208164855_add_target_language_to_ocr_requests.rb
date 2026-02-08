class AddTargetLanguageToOcrRequests < ActiveRecord::Migration[8.1]
  def change
    add_column :ocr_requests, :target_language, :string, default: "RU"
  end
end
