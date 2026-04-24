class AddMirroringTypeToRepositories < ActiveRecord::Migration[6.1]
  def change
    add_column :repositories, :mirroring_type, :string, limit: 16, default: nil
  end
end
