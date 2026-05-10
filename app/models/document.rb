class Document < ApplicationRecord
  has_many :ocr_requests, dependent: :destroy

  validates :name, presence: true

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
end
