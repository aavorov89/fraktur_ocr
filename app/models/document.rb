class Document < ApplicationRecord
  # A correction/translation still "processing" after this long is treated as
  # lost (worker restart), so the button works again.
  TEXT_JOB_STALE_AFTER = 5.minutes
  TARGET_LANGUAGES = %w[RU CS EN].freeze

  has_many :ocr_requests, dependent: :destroy
  has_many :page_layouts, dependent: :destroy

  enum :correction_status, { idle: 0, processing: 1, completed: 2, failed: 3 }, prefix: :correction
  enum :translation_status, { idle: 0, processing: 1, completed: 2, failed: 3 }, prefix: :translation

  validates :name, presence: true
  validates :target_language, inclusion: { in: TARGET_LANGUAGES }

  after_update_commit -> { broadcast_panel(:corrected) }, if: -> { saved_changes.keys.any? { _1.start_with?("correct") } }
  after_update_commit -> { broadcast_panel(:translation) }, if: -> { saved_changes.keys.any? { _1.start_with?("translat") || _1 == "target_language" } }

  # Absolute path of the server-side PDF copy under PDF_ROOT_DIR.
  # The Go render service receives the relative form ("<id>.pdf"), so the
  # resolution rule is `File.join(PDF_ROOT_DIR, "#{id}.pdf")` on both sides.
  def pdf_path
    File.join(self.class.pdf_root, "#{id}.pdf")
  end

  def pdf_stored?
    pdf_stored_at.present? && File.exist?(pdf_path)
  end

  def self.pdf_root
    ENV.fetch("PDF_ROOT_DIR", "/var/lib/fraktur/pdfs")
  end

  # Recognized fragments in click order — the buffer.
  def buffered_ocr_requests
    ocr_requests.buffered.order(:created_at, :id)
  end

  def self.join_fragments(ocr_requests)
    ocr_requests.select(&:completed?).filter_map { _1.recognized_text.presence }.join("\n\n")
  end

  def recognized_text
    self.class.join_fragments(buffered_ocr_requests)
  end

  def correction_running?
    correction_processing? && correction_requested_at&.after?(TEXT_JOB_STALE_AFTER.ago)
  end

  def translation_running?
    translation_processing? && translation_requested_at&.after?(TEXT_JOB_STALE_AFTER.ago)
  end

  # Empties all three text panels. Fragments still being recognized finish
  # in the background but stay out of the buffer; running correction or
  # translation jobs see the status reset and drop their result.
  def clear_buffer!
    transaction do
      ocr_requests.buffered.update_all(cleared_at: Time.current, updated_at: Time.current)
      update!(
        corrected_text: nil, correction_status: :idle, correction_error: nil, correction_requested_at: nil,
        translated_text: nil, translation_status: :idle, translation_error: nil, translation_requested_at: nil
      )
    end
    broadcast_panel(:recognized)
  end

  def broadcast_panel(name)
    broadcast_update_to [self, "ocr"], target: "#{name}_panel", partial: "documents/#{name}_panel", locals: { document: self }
  end
end
