defmodule Levee.Storage.Schemas.Blob do
  @moduledoc """
  Ecto schema for blob records.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  schema "blobs" do
    field(:tenant_id, :string)
    field(:sha, :string)
    field(:content, :binary)
    field(:size, :integer)
  end

  @doc false
  def changeset(blob, attrs) do
    blob
    |> cast(attrs, [:tenant_id, :sha, :content, :size])
    |> validate_required([:tenant_id, :sha, :content, :size])
    |> unique_constraint([:tenant_id, :sha])
  end

  @doc """
  Convert a schema struct to the format expected by Storage.Behaviour.
  """
  def to_storage_format(%__MODULE__{} = blob) do
    %{
      sha: blob.sha,
      content: blob.content,
      size: blob.size
    }
  end
end
