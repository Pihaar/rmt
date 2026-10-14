class AddMirroringTypeToRepositories < ActiveRecord::Migration[8.1]
  def up
    return if column_exists?(:repositories, :mirroring_type)

    add_column :repositories, :mirroring_type, :string, limit: 16, default: nil
  end

  def down
    return unless column_exists?(:repositories, :mirroring_type)

    remove_column :repositories, :mirroring_type
  end
end
