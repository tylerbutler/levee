defmodule Levee.Repo.Migrations.CreateRefs do
  use Ecto.Migration

  def change do
    create table(:refs, primary_key: false) do
      add(:tenant_id, :string, null: false)
      add(:ref_path, :string, null: false)
      add(:sha, :string, null: false)
    end

    create(unique_index(:refs, [:tenant_id, :ref_path], name: :refs_tenant_path_index))
  end
end
