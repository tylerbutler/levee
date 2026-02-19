defmodule Levee.Store.Migrations.CreateDocuments do
  use Ecto.Migration

  def change do
    create table(:documents, primary_key: false) do
      add(:tenant_id, :string, null: false)
      add(:id, :string, null: false)
      add(:sequence_number, :bigint, null: false, default: 0)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:documents, [:tenant_id, :id], name: :documents_tenant_id_id_index))
  end
end
