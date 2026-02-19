defmodule Levee.Storage.Schemas.Commit do
  @moduledoc """
  Ecto schema for commit records.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  schema "commits" do
    field(:tenant_id, :string)
    field(:sha, :string)
    field(:tree, :string)
    field(:parents, {:array, :string}, default: [])
    field(:message, :string)
    field(:author, :map)
    field(:committer, :map)
  end

  @doc false
  def changeset(commit, attrs) do
    commit
    |> cast(attrs, [:tenant_id, :sha, :tree, :parents, :message, :author, :committer])
    |> validate_required([:tenant_id, :sha, :tree, :author, :committer])
    |> unique_constraint([:tenant_id, :sha])
  end

  @doc """
  Convert a schema struct to the format expected by Storage.Behaviour.
  """
  def to_storage_format(%__MODULE__{} = commit) do
    %{
      sha: commit.sha,
      tree: commit.tree,
      parents: commit.parents,
      message: commit.message,
      author: commit.author,
      committer: commit.committer
    }
  end
end
