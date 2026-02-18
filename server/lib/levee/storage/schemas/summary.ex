defmodule Levee.Storage.Schemas.Summary do
  @moduledoc """
  Ecto schema for summary records.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  schema "summaries" do
    field(:tenant_id, :string)
    field(:document_id, :string)
    field(:sequence_number, :integer)
    field(:handle, :string)
    field(:tree_sha, :string)
    field(:commit_sha, :string)
    field(:parent_handle, :string)
    field(:message, :string)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc false
  def changeset(summary, attrs) do
    summary
    |> cast(attrs, [
      :tenant_id,
      :document_id,
      :sequence_number,
      :handle,
      :tree_sha,
      :commit_sha,
      :parent_handle,
      :message
    ])
    |> validate_required([:tenant_id, :document_id, :sequence_number, :handle])
    |> unique_constraint([:tenant_id, :document_id, :sequence_number])
    |> unique_constraint([:tenant_id, :document_id, :handle])
  end

  @doc """
  Convert a schema struct to the format expected by Storage.Behaviour.
  """
  def to_storage_format(%__MODULE__{} = summary) do
    %{
      handle: summary.handle,
      tenant_id: summary.tenant_id,
      document_id: summary.document_id,
      sequence_number: summary.sequence_number,
      tree_sha: summary.tree_sha,
      commit_sha: summary.commit_sha,
      parent_handle: summary.parent_handle,
      message: summary.message,
      created_at: summary.inserted_at
    }
  end
end
