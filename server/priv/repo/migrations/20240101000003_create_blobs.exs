defmodule Levee.Repo.Migrations.CreateBlobs do
  use Ecto.Migration

  def change do
    create table(:blobs, primary_key: false) do
      add(:tenant_id, :string, null: false)
      add(:sha, :string, null: false)
      add(:content, :binary, null: false)
      add(:size, :bigint, null: false)
    end

    create(unique_index(:blobs, [:tenant_id, :sha], name: :blobs_tenant_sha_index))
  end
end
