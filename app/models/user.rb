class User < ApplicationRecord
  validates :access_key, presence: true, uniqueness: true
  validates :name, presence: true

  before_validation :generate_access_key, on: :create, unless: :access_key?

  def self.authenticate(key)
    find_by(access_key: key)
  end

  private

  def generate_access_key
    phrases = [
      "templar-crusade",
      "viking-conquest",
      "samurai-honor",
      "spartan-warrior",
      "mongol-empire",
      "roman-legion"
    ]
    phrase = phrases.sample
    random = SecureRandom.alphanumeric(25).downcase
    self.access_key = "#{phrase}-#{random}"
  end
end
