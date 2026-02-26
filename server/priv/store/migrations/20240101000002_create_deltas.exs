defmodule Levee.Store.Migrations.CreateDeltas do
  use Ecto.Migration

  def change do
    create table(:deltas, primary_key: false) do
      add(:tenant_id, :string, null: false)
      add(:document_id, :string, null: false)
      add(:sequence_number, :bigint, null: false)
      add(:client_id, :string)
      add(:client_sequence_number, :bigint, null: false, default: 0)
      add(:reference_sequence_number, :bigint, null: false, default: 0)
      add(:minimum_sequence_number, :bigint, null: false, default: 0)
      add(:type, :string, null: false)
      add(:contents, :jsonb)
      add(:metadata, :jsonb)
      add(:timestamp, :bigint, null: false)
    end

    create(
      unique_index(:deltas, [:tenant_id, :document_id, :sequence_number],
        name: :deltas_tenant_doc_sn_index
      )
    )

    create(index(:deltas, [:tenant_id, :document_id]))
  end
end
