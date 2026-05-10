require "test_helper"

class RenderEnqueuerTest < ActiveSupport::TestCase
  setup do
    ActiveRecord::Base.connection.execute("DELETE FROM river_job")
  end

  test "inserts a row into river_job with the expected kind and args" do
    document = Document.create!(name: "Doc")
    ocr_request = document.ocr_requests.create!(
      page_number: 17,
      rect_x: 100.5,
      rect_y: 200.0,
      rect_w: 320.0,
      rect_h: 80.0
    )

    RenderEnqueuer.enqueue(ocr_request)

    rows = ActiveRecord::Base.connection.exec_query(
      "SELECT kind, queue, state, max_attempts, priority, args FROM river_job"
    ).to_a

    assert_equal 1, rows.size
    row = rows.first
    assert_equal RenderEnqueuer::KIND, row["kind"]
    assert_equal RenderEnqueuer::QUEUE, row["queue"]
    assert_equal "available", row["state"]
    assert_equal RenderEnqueuer::MAX_ATTEMPTS, row["max_attempts"]
    assert_equal RenderEnqueuer::PRIORITY, row["priority"]

    args = JSON.parse(row["args"])
    assert_equal ocr_request.id, args["ocr_request_id"]
    assert_equal "#{document.id}.pdf", args["pdf_path"]
    assert_equal 17, args["page"]
    assert_equal({ "x" => 100.5, "y" => 200.0, "w" => 320.0, "h" => 80.0 }, args["rect_pts"])
  end
end
