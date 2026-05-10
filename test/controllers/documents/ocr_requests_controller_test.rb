require "test_helper"

module Documents
  class OcrRequestsControllerTest < ActionDispatch::IntegrationTest
    setup do
      ActiveRecord::Base.connection.execute("DELETE FROM river_job")
      @document = Document.create!(name: "Doc")

      @user = User.create!(name: "Tester", access_key: "test-#{SecureRandom.hex(4)}")
      post login_path, params: { access_key: @user.access_key }
    end

    test "create accepts page_number and rect_pts and enqueues a render job" do
      assert_difference -> { @document.ocr_requests.count }, 1 do
        post document_ocr_requests_path(@document),
          params: {
            ocr_request: {
              page_number: 17,
              rect_pts: { x: 100.5, y: 200.0, w: 320.0, h: 80.0 }
            }
          },
          as: :json,
          headers: { "Accept" => "text/vnd.turbo-stream.html" }
      end

      assert_response :success

      ocr_request = @document.ocr_requests.last
      assert_equal 17, ocr_request.page_number
      assert_in_delta 100.5, ocr_request.rect_x.to_f, 0.0001
      assert_in_delta 200.0, ocr_request.rect_y.to_f, 0.0001
      assert_in_delta 320.0, ocr_request.rect_w.to_f, 0.0001
      assert_in_delta 80.0, ocr_request.rect_h.to_f, 0.0001
      assert_nil ocr_request.crop_data

      job_count = ActiveRecord::Base.connection.exec_query(
        "SELECT count(*) AS c FROM river_job WHERE kind = 'render_pdf_crop'"
      ).first["c"]
      assert_equal 1, job_count
    end

    test "create rejects missing rect_pts" do
      post document_ocr_requests_path(@document),
        params: { ocr_request: { page_number: 1 } },
        as: :json,
        headers: { "Accept" => "text/vnd.turbo-stream.html" }

      assert_response :unprocessable_entity
    end
  end
end
