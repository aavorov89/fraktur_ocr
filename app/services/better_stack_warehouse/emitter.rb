require "net/http"
require "json"
require "uri"

module BetterStackWarehouse
  # Thread-safe in-memory buffer that asynchronously flushes batched events
  # to the BetterStack Warehouse ingest endpoint over HTTP. The producer
  # (`#push`) never blocks: on buffer overflow it drops oldest events. All
  # exceptions in the emitter are caught and logged - the emitter cannot
  # crash a request or a job.
  class Emitter
    attr_reader :dropped

    def initialize(config:, logger: nil, transport: nil)
      @config    = config
      @logger    = logger || (defined?(Rails) ? Rails.logger : Logger.new($stdout))
      @transport = transport
      @buffer    = []
      @mutex     = Mutex.new
      @cond      = ConditionVariable.new
      @running   = false
      @thread    = nil
      @dropped   = 0
    end

    def start
      return unless @config.enabled?
      @mutex.synchronize do
        return if @running
        @running = true
      end
      @thread = Thread.new { flusher_loop }
      @thread.name = "bsw-emitter" if @thread.respond_to?(:name=)
    end

    def stop
      @mutex.synchronize do
        @running = false
        @cond.broadcast
      end
      @thread&.join(@config.flush_interval_seconds + 2) if @thread
      drain
    end

    def push(event)
      return false unless @config.enabled?
      @mutex.synchronize do
        @buffer << event
        if @buffer.size > @config.buffer_max
          overflow = @buffer.size - @config.buffer_max
          @buffer.shift(overflow)
          @dropped += overflow
        end
        @cond.signal if @buffer.size >= @config.batch_size
      end
      true
    rescue => e
      warn_isolated("push", e)
      false
    end

    # Synchronously drain everything in the buffer. Called from #stop and
    # at_exit; also exposed for tests.
    def drain
      loop do
        batch = @mutex.synchronize { @buffer.shift(@config.batch_size) }
        break if batch.empty?
        send_batch(batch)
      end
    rescue => e
      warn_isolated("drain", e)
    end

    # Exposed for tests: pull and send up to batch_size events without
    # involving the flusher thread.
    def flush_once
      batch = @mutex.synchronize { @buffer.shift(@config.batch_size) }
      return 0 if batch.empty?
      send_batch(batch)
      batch.size
    rescue => e
      warn_isolated("flush_once", e)
      0
    end

    # Test helper: current buffered count.
    def buffered
      @mutex.synchronize { @buffer.size }
    end

    private

    def flusher_loop
      loop do
        @mutex.synchronize do
          break unless @running
          if @buffer.size < @config.batch_size
            @cond.wait(@mutex, @config.flush_interval_seconds)
          end
          break unless @running && @buffer.any?
        end
        flush_once
      end
    rescue => e
      warn_isolated("flusher_loop", e)
    end

    def send_batch(batch)
      if @transport
        @transport.call(batch)
        return
      end
      uri  = URI.parse(@config.ingest_url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl     = uri.scheme == "https"
      http.open_timeout = 5
      http.read_timeout = 10

      req = Net::HTTP::Post.new(uri.request_uri)
      req["Authorization"] = "Bearer #{@config.source_token}"
      req["Content-Type"]  = "application/json"
      req.body = JSON.dump(batch)

      response = http.request(req)
      unless (200..299).cover?(response.code.to_i)
        @logger.warn(
          "[BetterStackWarehouse] ingest non-2xx status=#{response.code} " \
          "dropped_batch_size=#{batch.size}"
        )
      end
    rescue => e
      warn_isolated("send_batch", e)
    end

    def warn_isolated(where, error)
      @logger.warn("[BetterStackWarehouse] #{where}: #{error.class}: #{error.message}")
    end
  end
end
