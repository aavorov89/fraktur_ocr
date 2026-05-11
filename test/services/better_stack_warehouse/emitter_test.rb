require "test_helper"

class BetterStackWarehouse::EmitterTest < ActiveSupport::TestCase
  # Build a config that bypasses the Rails.env=="test" guard so the emitter
  # actually accepts events. Real ingestion is replaced with a transport
  # lambda so no network calls are made.
  def build_config(batch_size: 3, buffer_max: 5, flush_interval: 1)
    BetterStackWarehouse::Config.new(
      ingest_url:             "https://example.test/ingest",
      source_token:           "test-token",
      batch_size:             batch_size,
      flush_interval_seconds: flush_interval,
      buffer_max:             buffer_max,
      rails_env:              "development"
    )
  end

  def make_emitter(**config_overrides)
    sent = []
    transport = ->(batch) { sent << batch }
    cfg = build_config(**config_overrides)
    [BetterStackWarehouse::Emitter.new(config: cfg, transport: transport), sent]
  end

  test "buffers events and flushes them in one batch" do
    emitter, sent = make_emitter(batch_size: 3)
    3.times { |i| emitter.push(event: i) }
    emitter.flush_once
    assert_equal 1, sent.size
    assert_equal 3, sent.first.size
    assert_equal 0, emitter.buffered
  end

  test "flush_once respects batch_size cap" do
    emitter, sent = make_emitter(batch_size: 2, buffer_max: 10)
    5.times { |i| emitter.push(event: i) }
    emitter.flush_once
    assert_equal 1, sent.size
    assert_equal 2, sent.first.size
    assert_equal 3, emitter.buffered
  end

  test "drops oldest events on buffer overflow without blocking producer" do
    emitter, _sent = make_emitter(batch_size: 100, buffer_max: 3)
    7.times { |i| emitter.push(seq: i) }
    assert_equal 3, emitter.buffered
    assert_equal 4, emitter.dropped
    emitter.flush_once
  end

  test "is a no-op when config is disabled" do
    disabled = BetterStackWarehouse::Config.new(
      ingest_url: nil, source_token: nil,
      batch_size: 10, flush_interval_seconds: 1, buffer_max: 10,
      rails_env: "development"
    )
    sent = []
    emitter = BetterStackWarehouse::Emitter.new(
      config: disabled, transport: ->(b) { sent << b }
    )
    assert_equal false, emitter.push(event: 1)
    assert_equal 0, emitter.buffered
    emitter.flush_once
    assert_empty sent
  end

  test "swallows exceptions from the transport and logs" do
    cfg = build_config
    logger = Logger.new(StringIO.new)
    boom = ->(_batch) { raise "ingest exploded" }
    emitter = BetterStackWarehouse::Emitter.new(config: cfg, transport: boom, logger: logger)
    emitter.push(event: 1)
    # Must not raise.
    assert_nothing_raised { emitter.flush_once }
  end

  test "drain flushes everything in multiple batches" do
    emitter, sent = make_emitter(batch_size: 2, buffer_max: 10)
    5.times { |i| emitter.push(seq: i) }
    emitter.drain
    assert_equal 0, emitter.buffered
    assert_equal [2, 2, 1], sent.map(&:size)
  end
end
