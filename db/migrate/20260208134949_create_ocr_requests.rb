class CreateOcrRequests < ActiveRecord::Migration[8.1]
  def change
    create_table :ocr_requests do |t|
      t.references :document, null: false, foreign_key: true
      t.integer :page_number, null: false
      t.text :crop_data, null: false
      t.integer :status, default: 0, null: false
      t.text :recognized_text
      t.text :error_message
      t.timestamps
    end

    add_index :ocr_requests, [:document_id, :created_at]
  end
end
