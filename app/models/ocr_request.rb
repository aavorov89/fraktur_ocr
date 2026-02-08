class OcrRequest < ApplicationRecord
  belongs_to :document

  enum :status, { pending: 0, processing: 1, completed: 2, failed: 3 }

  validates :page_number, presence: true, numericality: { greater_than: 0 }
  validates :crop_data, presence: true

  # Broadcast updates to the document's Turbo Stream channel
  after_update_commit :broadcast_result

  private

  def broadcast_result
    broadcast_replace_to(
      [document, "ocr"],
      target: "ocr_panel",
      partial: "documents/ocr_panel",
      locals: { ocr_request: self }
    )

    broadcast_replace_to(
      [document, "ocr"],
      target: "translation_panel",
      partial: "documents/translation_panel",
      locals: { ocr_request: self }
    )
  end
end
