class CreatePageLayouts < ActiveRecord::Migration[8.1]
  def change
    create_table :page_layouts do |t|
      t.references :document, null: false, foreign_key: true
      t.integer :page_number, null: false
      t.integer :status, null: false, default: 0
      # Text regions detected by Mistral OCR, normalized to 0..1 of the page
      # size: [{ "x", "y", "w", "h", "type" }, ...]
      t.jsonb :regions, null: false, default: []
      t.string :model
      t.text :error_message
      t.timestamps
    end

    add_index :page_layouts, [:document_id, :page_number], unique: true
  end
end
