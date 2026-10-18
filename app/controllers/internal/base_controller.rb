# Callbacks from the Go render service, authenticated by a shared secret.
class Internal::BaseController < ActionController::API
  before_action :verify_internal_auth

  private

  def verify_internal_auth
    expected = ENV.fetch("INTERNAL_AUTH_SECRET")
    provided = request.headers["X-Internal-Auth"].to_s
    head(:unauthorized) unless ActiveSupport::SecurityUtils.secure_compare(expected, provided)
  end
end
