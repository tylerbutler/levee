defmodule Levee.Repo.Migrations.CreateCommits do
  use Ecto.Migration

  def change do
    create table(:commits, primary_key: false) do
      add(:tenant_id, :string, null: false)
      add(:sha, :string, null: false)
      add(:tree, :string, null: false)
      add(:parents, {:array, :string}, null: false, default: [])
      add(:message, :text)
      add(:author, :jsonb, null: false)
      add(:committer, :jsonb, null: false)
    end

    create(unique_index(:commits, [:tenant_id, :sha], name: :commits_tenant_sha_index))
  end
end
