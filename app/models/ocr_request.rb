class OcrRequest < ApplicationRecord
  belongs_to :document

  enum :status, { pending: 0, processing: 1, completed: 2, failed: 3 }

  validates :page_number, presence: true, numericality: { greater_than: 0 }
  # Rect coords are required only on the server-rendered path. The browser-
  # rendered path (sync-in-progress fallback) sends a pre-cropped JPEG and
  # leaves these columns null.
  validates :rect_x, :rect_y, :rect_w, :rect_h, presence: true, numericality: true, if: :rect_partially_present?
  validates :rect_w, :rect_h, numericality: { greater_than: 0 }, if: :rect_partially_present?

  # Broadcast updates to the document's Turbo Stream channel
  after_update_commit :broadcast_result

  private

  def rect_partially_present?
    rect_x.present? || rect_y.present? || rect_w.present? || rect_h.present?
  end

  def broadcast_result
    broadcast_update_to(
      [document, "ocr"],
      target: "ocr_panel",
      partial: "documents/ocr_panel",
      locals: { ocr_request: self }
    )

    broadcast_update_to(
      [document, "ocr"],
      target: "translation_panel",
      partial: "documents/translation_panel",
      locals: { ocr_request: self }
    )
  end
end
