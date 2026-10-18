class AddTextBuffer < ActiveRecord::Migration[8.1]
  def change
    # Each click on a detected text region appends one ocr_request to the
    # document's buffer; "Clear" stamps cleared_at instead of deleting rows.
    add_column :ocr_requests, :region_index, :integer
    add_column :ocr_requests, :cleared_at, :datetime
    # One buffered fragment per region: a second click is a no-op.
    add_index :ocr_requests, [:document_id, :page_number, :region_index],
              unique: true, where: "cleared_at IS NULL AND region_index IS NOT NULL",
              name: "index_ocr_requests_on_buffered_region"

    # Pre-buffer requests were free-hand selections shown one at a time; keep
    # them out of the new buffer.
    reversible do |dir|
      dir.up { execute "UPDATE ocr_requests SET cleared_at = updated_at" }
    end

    # Correction and translation now run over the whole buffer, on demand.
    change_table :documents do |t|
      t.text :corrected_text
      t.integer :correction_status, null: false, default: 0
      t.text :correction_error
      t.datetime :correction_requested_at
      t.text :translated_text
      t.integer :translation_status, null: false, default: 0
      t.text :translation_error
      t.datetime :translation_requested_at
      t.string :target_language, null: false, default: "RU"
    end
  end
end
