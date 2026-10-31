class OcrRequest < ApplicationRecord
  belongs_to :document

  enum :status, { pending: 0, processing: 1, completed: 2, failed: 3 }

  # In the document's buffer until "Clear" stamps cleared_at.
  scope :buffered, -> { where(cleared_at: nil) }

  validates :page_number, presence: true, numericality: { greater_than: 0 }
  validates :region_index, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
  # Rect coords are required only on the server-rendered path. The browser-
  # rendered path (sync-in-progress fallback) sends a pre-cropped JPEG and
  # leaves these columns null.
  validates :rect_x, :rect_y, :rect_w, :rect_h, presence: true, numericality: true, if: :rect_partially_present?
  validates :rect_w, :rect_h, numericality: { greater_than: 0 }, if: :rect_partially_present?

  # Re-render the buffer (recognized text panel) on every state change.
  after_commit -> { document.broadcast_panel(:recognized) }, on: [:create, :update]

  # "<page>:<region index>" — how the PDF viewer identifies a clicked region.
  def region_key
    "#{page_number}:#{region_index}" unless region_index.nil?
  end

  private

  def rect_partially_present?
    rect_x.present? || rect_y.present? || rect_w.present? || rect_h.present?
  end
end
