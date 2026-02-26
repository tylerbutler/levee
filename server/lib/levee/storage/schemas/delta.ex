defmodule Levee.Storage.Schemas.Delta do
  @moduledoc """
  Ecto schema for delta (operation) records.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  schema "deltas" do
    field(:tenant_id, :string)
    field(:document_id, :string)
    field(:sequence_number, :integer)
    field(:client_id, :string)
    field(:client_sequence_number, :integer, default: 0)
    field(:reference_sequence_number, :integer, default: 0)
    field(:minimum_sequence_number, :integer, default: 0)
    field(:type, :string)
    field(:contents, :map)
    field(:metadata, :map)
    field(:timestamp, :integer)
  end

  @doc false
  def changeset(delta, attrs) do
    delta
    |> cast(attrs, [
      :tenant_id,
      :document_id,
      :sequence_number,
      :client_id,
      :client_sequence_number,
      :reference_sequence_number,
      :minimum_sequence_number,
      :type,
      :contents,
      :metadata,
      :timestamp
    ])
    |> validate_required([
      :tenant_id,
      :document_id,
      :sequence_number,
      :type,
      :timestamp
    ])
    |> unique_constraint([:tenant_id, :document_id, :sequence_number])
  end

  @doc """
  Convert a schema struct to the format expected by Storage.Behaviour.
  """
  def to_storage_format(%__MODULE__{} = delta) do
    %{
      sequence_number: delta.sequence_number,
      client_id: delta.client_id,
      client_sequence_number: delta.client_sequence_number,
      reference_sequence_number: delta.reference_sequence_number,
      minimum_sequence_number: delta.minimum_sequence_number,
      type: delta.type,
      contents: delta.contents,
      metadata: delta.metadata,
      timestamp: delta.timestamp
    }
  end
end
