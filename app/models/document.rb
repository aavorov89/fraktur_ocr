class Document < ApplicationRecord
  has_one_attached :file
  has_many :ocr_requests, dependent: :destroy

  validates :name, presence: true
  validates :file, presence: true
  validate :file_must_be_pdf

  private

  def file_must_be_pdf
    return unless file.attached?

    unless file.content_type == "application/pdf"
      errors.add(:file, "must be a PDF")
    end
  end
end
