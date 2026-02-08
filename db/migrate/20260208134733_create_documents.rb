class CreateDocuments < ActiveRecord::Migration[8.1]
  def change
    create_table :documents do |t|
      t.string :name, null: false
      t.timestamps
    end
  end
end
