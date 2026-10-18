class PageLayout < ApplicationRecord
  # A server-side render that hasn't reported back by then is assumed lost
  # (e.g. the river job was discarded) and may be requested again.
  STALE_AFTER = 2.minutes
  # Smallest edited region (fraction of the page side) — guards against
  # boxes collapsed to nothing.
  MIN_REGION_SIDE = 0.002

  belongs_to :document

  enum :status, { pending: 0, completed: 1, failed: 2 }

  # One row per page is enforced by the unique index (create_or_find_by
  # relies on it, so no uniqueness validation here).
  validates :page_number, presence: true, numericality: { greater_than: 0 }

  # Push finished detections and region edits to every open viewer of the
  # document; the PDF viewer controller picks them up from the appended
  # element.
  after_commit :broadcast_result, on: [:create, :update],
               if: -> { (saved_change_to_status? || saved_change_to_regions?) && !pending? }

  # True when a fresh detection should be started for this page.
  def detection_needed?
    failed? || (pending? && updated_at < STALE_AFTER.ago)
  end

  # Normalized page rect {x, y, w, h} (0..1, top-left origin) clamped to the
  # page, or nil if it is not a usable box.
  def self.normalize_rect(x:, y:, w:, h:)
    coords = [x, y, w, h].map { Float(_1, exception: false) }
    return nil unless coords.all? { _1&.finite? }

    x, y, w, h = coords
    left, top = x.clamp(0.0, 1.0), y.clamp(0.0, 1.0)
    right, bottom = (x + w).clamp(0.0, 1.0), (y + h).clamp(0.0, 1.0)
    return nil if right - left < MIN_REGION_SIDE || bottom - top < MIN_REGION_SIDE

    { "x" => left.round(5), "y" => top.round(5), "w" => (right - left).round(5), "h" => (bottom - top).round(5) }
  end

  # Moves/resizes one region (user edit). The row lock keeps concurrent
  # edits of other regions on the same page from overwriting each other.
  def update_region!(index, rect)
    with_lock do
      updated = regions.deep_dup
      updated[index] = updated[index].merge(rect, "edited" => true)
      update!(regions: updated)
    end
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
