require "test_helper"

class BetterStackWarehouse::PipelineTest < ActiveSupport::TestCase
  setup do
    @document = Document.create!(name: "Doc")
    @ocr_request = @document.ocr_requests.create!(
      page_number: 1, rect_x: 0, rect_y: 0, rect_w: 100, rect_h: 100,
      target_language: "RU"
    )

    @sent = []
    @prev_emitter = BetterStackWarehouse.emitter
    cfg = BetterStackWarehouse::Config.new(
      ingest_url: "https://example.test/ingest",
      source_token: "test-token",
      batch_size: 10, flush_interval_seconds: 1, buffer_max: 100,
      rails_env: "development"
    )
    BetterStackWarehouse.emitter = BetterStackWarehouse::Emitter.new(
      config: cfg, transport: ->(batch) { @sent.concat(batch) }
    )
  end

  teardown do
    BetterStackWarehouse.emitter = @prev_emitter
  end

  test "record_stage merges values into ocr_requests.metrics under the stage key" do
    BetterStackWarehouse::Pipeline.record_stage(:ocr,
      ocr_request_id: @ocr_request.id,
      ms: 1234, tokens_in: 100, tokens_out: 50
    )
    @ocr_request.reload
    assert_equal({ "ms" => 1234, "tokens_in" => 100, "tokens_out" => 50 },
                 @ocr_request.metrics["ocr"])
  end

  test "record_stage subsequent call merges rather than overwriting" do
    BetterStackWarehouse::Pipeline.record_stage(:ocr,
      ocr_request_id: @ocr_request.id, ms: 100, tokens_in: 1)
    BetterStackWarehouse::Pipeline.record_stage(:ocr,
      ocr_request_id: @ocr_request.id, tokens_out: 2)
    @ocr_request.reload
    assert_equal({ "ms" => 100, "tokens_in" => 1, "tokens_out" => 2 },
                 @ocr_request.metrics["ocr"])
  end

  test "record_stage with nil values does not blot existing data" do
    BetterStackWarehouse::Pipeline.record_stage(:ocr,
      ocr_request_id: @ocr_request.id, ms: 500, tokens_in: 10)
    BetterStackWarehouse::Pipeline.record_stage(:ocr,
      ocr_request_id: @ocr_request.id, tokens_out: nil)
    @ocr_request.reload
    assert_equal 500, @ocr_request.metrics["ocr"]["ms"]
    assert_equal 10, @ocr_request.metrics["ocr"]["tokens_in"]
    refute @ocr_request.metrics["ocr"].key?("tokens_out")
  end

  test "record_stage with an unknown ocr_request_id is a safe no-op" do
    assert_nothing_raised do
      BetterStackWarehouse::Pipeline.record_stage(:ocr,
        ocr_request_id: 999_999_999, ms: 1)
    end
  end

  test "flush emits a single warehouse event with the full schema" do
    @ocr_request.update!(
      recognized_text: "abc",
      corrected_text: "abcd",
      translated_text: "trans"
    )
    BetterStackWarehouse::Pipeline.record_stage(:render,
      ocr_request_id: @ocr_request.id, ms: 50, pdf_page_count: 10, render_dpi: 300)
    BetterStackWarehouse::Pipeline.record_stage(:ocr,
      ocr_request_id: @ocr_request.id, ms: 1200, model: "claude-sonnet-4-20250514",
      tokens_in: 100, tokens_out: 200, cost_usd: 0.0033,
      image_size_bytes: 12_345)
    BetterStackWarehouse::Pipeline.record_stage(:correction,
      ocr_request_id: @ocr_request.id, ms: 800, model: "gpt-4o",
      tokens_in: 50, tokens_out: 60, cost_usd: 0.000725)
    BetterStackWarehouse::Pipeline.record_stage(:translation,
      ocr_request_id: @ocr_request.id, ms: 400, chars: 4, cost_usd: 0.0001)

    BetterStackWarehouse::Pipeline.flush(@ocr_request.id, status: :completed)
    BetterStackWarehouse.emitter.drain

    assert_equal 1, @sent.size
    event = @sent.first
    assert_equal @ocr_request.id, event[:ocr_request_id]
    assert_equal @document.id, event[:doc_id]
    assert_equal "pdf", event[:source_format]
    assert_equal "server", event[:pipeline_path]
    assert_equal 50,  event[:render_ms]
    assert_equal 10,  event[:pdf_page_count]
    assert_equal 300, event[:render_dpi]
    assert_equal "claude-sonnet-4-20250514", event[:ocr_model]
    assert_equal 100, event[:ocr_tokens_in]
    assert_equal 200, event[:ocr_tokens_out]
    assert_equal "gpt-4o", event[:correction_model]
    assert_equal 50, event[:correction_tokens_in]
    assert_equal 4,  event[:translation_chars]
    assert_equal "completed", event[:status]
    assert_nil   event[:failure_stage]
    assert_equal "RU", event[:target_language]
  end

  test "flush on terminal failure includes failure_stage and error_class" do
    BetterStackWarehouse::Pipeline.record_stage(:ocr,
      ocr_request_id: @ocr_request.id, ms: 100, tokens_in: 1, tokens_out: 2)
    BetterStackWarehouse::Pipeline.flush(@ocr_request.id,
      status: :failed, failure_stage: :correction, error_class: "Net::ReadTimeout")
    BetterStackWarehouse.emitter.drain

    assert_equal 1, @sent.size
    event = @sent.first
    assert_equal "failed", event[:status]
    assert_equal "correction", event[:failure_stage]
    assert_equal "Net::ReadTimeout", event[:error_class]
    # Stages that didn't run are nil rather than absent.
    assert_nil event[:translation_ms]
  end

  test "pipeline_path is browser when no render stage was recorded" do
    BetterStackWarehouse::Pipeline.record_stage(:ocr,
      ocr_request_id: @ocr_request.id, ms: 1)
    BetterStackWarehouse::Pipeline.flush(@ocr_request.id, status: :completed)
    BetterStackWarehouse.emitter.drain
    assert_equal "browser", @sent.first[:pipeline_path]
  end
end
