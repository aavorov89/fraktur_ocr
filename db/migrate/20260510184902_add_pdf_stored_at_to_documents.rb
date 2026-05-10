class AddPdfStoredAtToDocuments < ActiveRecord::Migration[8.1]
  def change
    add_column :documents, :pdf_stored_at, :datetime
  end
end
