defmodule Levee.Storage.Schemas.Ref do
  @moduledoc """
  Ecto schema for ref (Git reference) records.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  schema "refs" do
    field(:tenant_id, :string)
    field(:ref_path, :string)
    field(:sha, :string)
  end

  @doc false
  def changeset(ref, attrs) do
    ref
    |> cast(attrs, [:tenant_id, :ref_path, :sha])
    |> validate_required([:tenant_id, :ref_path, :sha])
    |> unique_constraint([:tenant_id, :ref_path])
  end

  @doc """
  Convert a schema struct to the format expected by Storage.Behaviour.
  """
  def to_storage_format(%__MODULE__{} = ref) do
    %{
      ref: ref.ref_path,
      sha: ref.sha
    }
  end
end
