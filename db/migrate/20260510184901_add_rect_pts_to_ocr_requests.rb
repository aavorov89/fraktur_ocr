class AddRectPtsToOcrRequests < ActiveRecord::Migration[8.1]
  def change
    change_table :ocr_requests do |t|
      t.decimal :rect_x, precision: 10, scale: 4
      t.decimal :rect_y, precision: 10, scale: 4
      t.decimal :rect_w, precision: 10, scale: 4
      t.decimal :rect_h, precision: 10, scale: 4
    end

    change_column_null :ocr_requests, :crop_data, true
  end
end
