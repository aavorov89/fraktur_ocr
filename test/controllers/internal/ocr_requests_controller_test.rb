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
end
