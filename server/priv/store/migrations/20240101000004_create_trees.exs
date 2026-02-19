defmodule Levee.Store.Migrations.CreateTrees do
  use Ecto.Migration

  def change do
    create table(:trees, primary_key: false) do
      add(:tenant_id, :string, null: false)
      add(:sha, :string, null: false)
      add(:entries, {:array, :jsonb}, null: false, default: [])
    end

    create(unique_index(:trees, [:tenant_id, :sha], name: :trees_tenant_sha_index))
  end
end
