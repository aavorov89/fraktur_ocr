class Internal::OcrRequestsController < ActionController::API
  before_action :verify_internal_auth

  def render_done
    ocr_request_id = params[:id].to_i
    body = parse_render_body(request.raw_post)

    if body.values_at("render_ms", "pdf_page_count", "render_dpi").any?
      ActiveSupport::Notifications.instrument(
        "fraktur_ocr.render",
        ocr_request_id: ocr_request_id,
        render_ms:      body["render_ms"],
        pdf_page_count: body["pdf_page_count"],
        render_dpi:     body["render_dpi"]
      )
    end

    OcrJob.perform_later(ocr_request_id)
    head :no_content
  end

  private

  # Best-effort parse. The Go renderer sends a JSON object with render_ms,
  # pdf_page_count, render_dpi keys; older builds may still POST an empty
  # body, which must remain valid (returns an empty hash, no notification
  # fires). Malformed integers / missing keys default to nil; non-JSON
  # bodies are tolerated and treated as empty.
  def parse_render_body(raw)
    return {} if raw.blank?
    parsed = JSON.parse(raw)
    return {} unless parsed.is_a?(Hash)
    {
      "render_ms"      => integer_or_nil(parsed["render_ms"]),
      "pdf_page_count" => integer_or_nil(parsed["pdf_page_count"]),
      "render_dpi"     => integer_or_nil(parsed["render_dpi"])
    }
  rescue JSON::ParserError
    {}
  end

  def integer_or_nil(value)
    return nil if value.nil?
    Integer(value)
  rescue ArgumentError, TypeError
    nil
  end

  def verify_internal_auth
    expected = ENV.fetch("INTERNAL_AUTH_SECRET")
    provided = request.headers["X-Internal-Auth"].to_s
    head(:unauthorized) unless ActiveSupport::SecurityUtils.secure_compare(expected, provided)
  end
end
