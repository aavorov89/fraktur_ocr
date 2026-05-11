require "test_helper"

class Internal::OcrRequestsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @secret = "test-internal-secret-#{SecureRandom.hex(4)}"
    @prev_secret = ENV["INTERNAL_AUTH_SECRET"]
    ENV["INTERNAL_AUTH_SECRET"] = @secret
  end

  teardown do
    ENV["INTERNAL_AUTH_SECRET"] = @prev_secret
  end

  test "rejects request with no X-Internal-Auth header" do
    assert_no_enqueued_jobs only: OcrJob do
      post render_done_internal_ocr_request_path(123)
    end
    assert_response :unauthorized
  end

  test "rejects request with wrong X-Internal-Auth header" do
    assert_no_enqueued_jobs only: OcrJob do
      post render_done_internal_ocr_request_path(123),
           headers: { "X-Internal-Auth" => "wrong-secret" }
    end
    assert_response :unauthorized
  end

  test "enqueues OcrJob with correct id and returns 204 when header matches" do
    assert_enqueued_with(job: OcrJob, args: [456]) do
      post render_done_internal_ocr_request_path(456),
           headers: { "X-Internal-Auth" => @secret }
    end
    assert_response :no_content
  end

  test "empty body still produces a valid 204 (backward-compat with old renderer)" do
    document = Document.create!(name: "Doc")
    ocr_request = document.ocr_requests.create!(
      page_number: 1, rect_x: 0, rect_y: 0, rect_w: 100, rect_h: 100
    )

    post render_done_internal_ocr_request_path(ocr_request.id),
         headers: { "X-Internal-Auth" => @secret, "Content-Type" => "application/json" },
         params: "{}"
    assert_response :no_content

    ocr_request.reload
    assert_equal({}, ocr_request.metrics)
  end

  test "render body fields land in ocr_requests.metrics under the render key" do
    document = Document.create!(name: "Doc")
    ocr_request = document.ocr_requests.create!(
      page_number: 1, rect_x: 0, rect_y: 0, rect_w: 100, rect_h: 100
    )

    body = { render_ms: 250, pdf_page_count: 12, render_dpi: 300 }.to_json
    post render_done_internal_ocr_request_path(ocr_request.id),
         headers: { "X-Internal-Auth" => @secret, "Content-Type" => "application/json" },
         params: body
    assert_response :no_content

    ocr_request.reload
    assert_equal 250, ocr_request.metrics.dig("render", "ms")
    assert_equal 12,  ocr_request.metrics.dig("render", "pdf_page_count")
    assert_equal 300, ocr_request.metrics.dig("render", "render_dpi")
  end

  test "missing or malformed render fields default to nil without crashing" do
    document = Document.create!(name: "Doc")
    ocr_request = document.ocr_requests.create!(
      page_number: 1, rect_x: 0, rect_y: 0, rect_w: 100, rect_h: 100
    )

    # Only one of the three fields is present; the other two are absent.
    body = { render_ms: 42 }.to_json
    post render_done_internal_ocr_request_path(ocr_request.id),
         headers: { "X-Internal-Auth" => @secret, "Content-Type" => "application/json" },
         params: body
    assert_response :no_content

    ocr_request.reload
    assert_equal 42, ocr_request.metrics.dig("render", "ms")
    assert_nil ocr_request.metrics.dig("render", "pdf_page_count")
    assert_nil ocr_request.metrics.dig("render", "render_dpi")
  end

end
