# Per-page processing analytics shipped to BetterStack Warehouse. Active
# only when BETTERSTACK_WAREHOUSE_INGEST_URL and BETTERSTACK_WAREHOUSE_SOURCE_TOKEN
# are both set; dev/test boot the same as before. The subscriber is always
# attached so ocr_requests.metrics is populated even without the emitter
# (useful for local debugging of stage timing without sending to BSW).
#
# The work runs in an after_initialize hook so the autoloader is fully
# wired before BetterStackWarehouse::* constants are referenced.

Rails.application.config.after_initialize do
  BetterStackWarehouse.config = BetterStackWarehouse::Config.from_env

  BetterStackWarehouse::PipelineSubscriber.attach!

  if BetterStackWarehouse.config.enabled?
    BetterStackWarehouse.emitter = BetterStackWarehouse::Emitter.new(config: BetterStackWarehouse.config)
    BetterStackWarehouse.emitter.start

    at_exit do
      BetterStackWarehouse.emitter&.stop
    rescue StandardError
      # never let at_exit crash the process
    end
  end
end
