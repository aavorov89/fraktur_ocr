class PageLayout < ApplicationRecord
  # A server-side render that hasn't reported back by then is assumed lost
  # (e.g. the river job was discarded) and may be requested again.
  STALE_AFTER = 2.minutes

  belongs_to :document

  enum :status, { pending: 0, completed: 1, failed: 2 }

  # One row per page is enforced by the unique index (create_or_find_by
  # relies on it, so no uniqueness validation here).
  validates :page_number, presence: true, numericality: { greater_than: 0 }

  # Push finished detections to every open viewer of the document; the PDF
  # viewer controller picks them up from the appended element.
  after_commit :broadcast_result, on: [:create, :update], if: -> { saved_change_to_status? && !pending? }

  # True when a fresh detection should be started for this page.
  def detection_needed?
    failed? || (pending? && updated_at < STALE_AFTER.ago)
  end

  def as_json(*)
    { page_number: page_number, status: status, regions: regions, error: error_message }
  end

  private

  def broadcast_result
    broadcast_append_to(
      [document, "ocr"],
      target: "page_layouts",
      partial: "documents/page_layout",
      locals: { page_layout: self }
    )
  end
end
