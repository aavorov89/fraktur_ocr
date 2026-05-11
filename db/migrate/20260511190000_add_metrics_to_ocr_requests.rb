class AddMetricsToOcrRequests < ActiveRecord::Migration[8.1]
  def change
    add_column :ocr_requests, :metrics, :jsonb, default: {}, null: false
  end
end
