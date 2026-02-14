class Document < ApplicationRecord
  has_many :ocr_requests, dependent: :destroy

  validates :name, presence: true
end
