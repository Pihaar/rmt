class AddMirroringTypeToRepositories < ActiveRecord::Migration[8.1]
  def change
    add_column :repositories, :mirroring_type, :string, limit: 16, default: nil
  end
end
