defmodule Levee.Store.Migrations.CreateSummaries do
  use Ecto.Migration

  def change do
    create table(:summaries, primary_key: false) do
      add(:tenant_id, :string, null: false)
      add(:document_id, :string, null: false)
      add(:sequence_number, :bigint, null: false)
      add(:handle, :string, null: false)
      add(:tree_sha, :string)
      add(:commit_sha, :string)
      add(:parent_handle, :string)
      add(:message, :text)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(
      unique_index(:summaries, [:tenant_id, :document_id, :sequence_number],
        name: :summaries_tenant_doc_sn_index
      )
    )

    create(
      unique_index(:summaries, [:tenant_id, :document_id, :handle],
        name: :summaries_tenant_doc_handle_index
      )
    )

    create(index(:summaries, [:tenant_id, :document_id]))
  end
end
