defmodule Levee.Storage.Schemas.Document do
  @moduledoc """
  Ecto schema for document records.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  schema "documents" do
    field(:tenant_id, :string)
    field(:id, :string)
    field(:sequence_number, :integer, default: 0)

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(document, attrs) do
    document
    |> cast(attrs, [:tenant_id, :id, :sequence_number])
    |> validate_required([:tenant_id, :id])
    |> unique_constraint([:tenant_id, :id])
  end

  @doc """
  Convert a schema struct to the format expected by Storage.Behaviour.
  """
  def to_storage_format(%__MODULE__{} = doc) do
    %{
      id: doc.id,
      tenant_id: doc.tenant_id,
      sequence_number: doc.sequence_number,
      created_at: doc.inserted_at,
      updated_at: doc.updated_at
    }
  end
end
