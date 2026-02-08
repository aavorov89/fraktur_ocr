class CreateUsers < ActiveRecord::Migration[8.1]
  def change
    create_table :users do |t|
      t.string :access_key
      t.string :name

      t.timestamps
    end
    add_index :users, :access_key, unique: true
  end
end
