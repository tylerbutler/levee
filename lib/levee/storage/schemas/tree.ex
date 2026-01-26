defmodule Levee.Storage.Schemas.Tree do
  @moduledoc """
  Ecto schema for tree records.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  schema "trees" do
    field(:tenant_id, :string)
    field(:sha, :string)
    field(:entries, {:array, :map}, default: [])
  end

  @doc false
  def changeset(tree, attrs) do
    tree
    |> cast(attrs, [:tenant_id, :sha, :entries])
    |> validate_required([:tenant_id, :sha, :entries])
    |> unique_constraint([:tenant_id, :sha])
  end

  @doc """
  Convert a schema struct to the format expected by Storage.Behaviour.
  """
  def to_storage_format(%__MODULE__{} = tree) do
    # Convert entries to atom-keyed maps
    entries =
      Enum.map(tree.entries, fn entry ->
        %{
          path: entry["path"],
          mode: entry["mode"],
          sha: entry["sha"],
          type: entry["type"]
        }
      end)

    %{
      sha: tree.sha,
      tree: entries
    }
  end
end
