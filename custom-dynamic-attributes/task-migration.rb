class CreateTasks < ActiveRecord::Migration[6.1]
  def change
    create_table :tasks do |t|
      t.string :name
      t.jsonb :properties, default: {}
      t.timestamps
    end
  end
end
