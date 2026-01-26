defmodule Levee.Storage.Postgres do
  @moduledoc """
  PostgreSQL storage implementation for the Fluid Framework server.

  This is a persistent storage backend using Ecto and PostgreSQL.
  Data is persisted across restarts.

  Uses the following tables:
  - documents - Document metadata
  - deltas - Sequenced operations
  - blobs - Git blob objects
  - trees - Git tree objects
  - commits - Git commit objects
  - refs - Git references
  - summaries - Document summaries
  """

  @behaviour Levee.Storage.Behaviour

  import Ecto.Query

  alias Levee.Repo
  alias Levee.Storage.Schemas.{Document, Delta, Blob, Tree, Commit, Ref, Summary}

  @max_deltas_per_request 2000

  # Document operations

  @impl Levee.Storage.Behaviour
  def create_document(tenant_id, document_id, params) do
    attrs = %{
      tenant_id: tenant_id,
      id: document_id,
      sequence_number: params[:sequence_number] || 0
    }

    case %Document{} |> Document.changeset(attrs) |> Repo.insert() do
      {:ok, doc} ->
        {:ok, Document.to_storage_format(doc)}

      {:error, %Ecto.Changeset{errors: errors}} ->
        if Keyword.has_key?(errors, :tenant_id) || Keyword.has_key?(errors, :id) do
          {:error, :already_exists}
        else
          {:error, errors}
        end
    end
  end

  @impl Levee.Storage.Behaviour
  def get_document(tenant_id, document_id) do
    query =
      from(d in Document,
        where: d.tenant_id == ^tenant_id and d.id == ^document_id
      )

    case Repo.one(query) do
      nil -> {:error, :not_found}
      doc -> {:ok, Document.to_storage_format(doc)}
    end
  end

  @impl Levee.Storage.Behaviour
  def update_document_sequence(tenant_id, document_id, sequence_number) do
    query =
      from(d in Document,
        where: d.tenant_id == ^tenant_id and d.id == ^document_id
      )

    case Repo.one(query) do
      nil ->
        {:error, :not_found}

      doc ->
        doc
        |> Document.changeset(%{sequence_number: sequence_number})
        |> Repo.update()
        |> case do
          {:ok, updated} -> {:ok, Document.to_storage_format(updated)}
          {:error, changeset} -> {:error, changeset.errors}
        end
    end
  end

  # Delta operations

  @impl Levee.Storage.Behaviour
  def store_delta(tenant_id, document_id, delta) do
    attrs = %{
      tenant_id: tenant_id,
      document_id: document_id,
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

    case %Delta{} |> Delta.changeset(attrs) |> Repo.insert() do
      {:ok, stored} -> {:ok, Delta.to_storage_format(stored)}
      {:error, changeset} -> {:error, changeset.errors}
    end
  end

  @impl Levee.Storage.Behaviour
  def get_deltas(tenant_id, document_id, opts \\ []) do
    from_sn = Keyword.get(opts, :from, -1)
    to_sn = Keyword.get(opts, :to, nil)
    limit = min(Keyword.get(opts, :limit, @max_deltas_per_request), @max_deltas_per_request)

    query =
      from(d in Delta,
        where: d.tenant_id == ^tenant_id and d.document_id == ^document_id,
        where: d.sequence_number > ^from_sn,
        order_by: [asc: d.sequence_number],
        limit: ^limit
      )

    query =
      if to_sn do
        from(d in query, where: d.sequence_number < ^to_sn)
      else
        query
      end

    deltas =
      Repo.all(query)
      |> Enum.map(&Delta.to_storage_format/1)

    {:ok, deltas}
  end

  # Blob operations

  @impl Levee.Storage.Behaviour
  def create_blob(tenant_id, content) when is_binary(content) do
    sha = compute_sha256(content)

    attrs = %{
      tenant_id: tenant_id,
      sha: sha,
      content: content,
      size: byte_size(content)
    }

    # Use upsert to handle duplicate SHAs (content-addressable storage)
    case %Blob{}
         |> Blob.changeset(attrs)
         |> Repo.insert(
           on_conflict: :nothing,
           conflict_target: [:tenant_id, :sha]
         ) do
      {:ok, blob} ->
        {:ok, Blob.to_storage_format(blob)}

      {:error, _} ->
        # If insert failed due to conflict, just return the existing blob data
        {:ok, %{sha: sha, content: content, size: byte_size(content)}}
    end
  end

  @impl Levee.Storage.Behaviour
  def get_blob(tenant_id, sha) do
    query =
      from(b in Blob,
        where: b.tenant_id == ^tenant_id and b.sha == ^sha
      )

    case Repo.one(query) do
      nil -> {:error, :not_found}
      blob -> {:ok, Blob.to_storage_format(blob)}
    end
  end

  # Tree operations

  @impl Levee.Storage.Behaviour
  def create_tree(tenant_id, entries) do
    # Serialize and hash the tree entries for the SHA
    tree_content = Jason.encode!(entries)
    sha = compute_sha256(tree_content)

    # Convert entries to maps for storage
    entries_for_storage =
      Enum.map(entries, fn entry ->
        %{
          "path" => entry.path || entry["path"],
          "mode" => entry.mode || entry["mode"],
          "sha" => entry.sha || entry["sha"],
          "type" => entry.type || entry["type"]
        }
      end)

    attrs = %{
      tenant_id: tenant_id,
      sha: sha,
      entries: entries_for_storage
    }

    case %Tree{}
         |> Tree.changeset(attrs)
         |> Repo.insert(
           on_conflict: :nothing,
           conflict_target: [:tenant_id, :sha]
         ) do
      {:ok, tree} ->
        {:ok, Tree.to_storage_format(tree)}

      {:error, _} ->
        # If insert failed due to conflict, return with the computed sha
        {:ok,
         %{
           sha: sha,
           tree:
             Enum.map(entries, fn entry ->
               %{
                 path: entry.path || entry["path"],
                 mode: entry.mode || entry["mode"],
                 sha: entry.sha || entry["sha"],
                 type: entry.type || entry["type"]
               }
             end)
         }}
    end
  end

  @impl Levee.Storage.Behaviour
  def get_tree(tenant_id, sha, opts \\ []) do
    query =
      from(t in Tree,
        where: t.tenant_id == ^tenant_id and t.sha == ^sha
      )

    case Repo.one(query) do
      nil ->
        {:error, :not_found}

      tree ->
        tree_data = Tree.to_storage_format(tree)

        if Keyword.get(opts, :recursive, false) do
          {:ok, expand_tree_recursive(tenant_id, tree_data)}
        else
          {:ok, tree_data}
        end
    end
  end

  defp expand_tree_recursive(tenant_id, tree) do
    expanded_entries =
      Enum.flat_map(tree.tree, fn entry ->
        case entry.type do
          "tree" ->
            case get_tree(tenant_id, entry.sha, recursive: true) do
              {:ok, subtree} ->
                Enum.map(subtree.tree, fn subentry ->
                  %{subentry | path: "#{entry.path}/#{subentry.path}"}
                end)

              {:error, _} ->
                [entry]
            end

          _ ->
            [entry]
        end
      end)

    %{tree | tree: expanded_entries}
  end

  # Commit operations

  @impl Levee.Storage.Behaviour
  def create_commit(tenant_id, params) do
    commit_content =
      Jason.encode!(%{
        tree: params["tree"],
        parents: params["parents"],
        message: params["message"],
        author: params["author"]
      })

    sha = compute_sha256(commit_content)
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    attrs = %{
      tenant_id: tenant_id,
      sha: sha,
      tree: params["tree"],
      parents: params["parents"] || [],
      message: params["message"],
      author: params["author"],
      committer:
        params["committer"] ||
          %{
            "name" => "Levee",
            "email" => "server@fluid.local",
            "date" => now
          }
    }

    case %Commit{}
         |> Commit.changeset(attrs)
         |> Repo.insert(
           on_conflict: :nothing,
           conflict_target: [:tenant_id, :sha]
         ) do
      {:ok, commit} ->
        {:ok, Commit.to_storage_format(commit)}

      {:error, _} ->
        # If insert failed due to conflict, return with computed values
        {:ok,
         %{
           sha: sha,
           tree: attrs.tree,
           parents: attrs.parents,
           message: attrs.message,
           author: attrs.author,
           committer: attrs.committer
         }}
    end
  end

  @impl Levee.Storage.Behaviour
  def get_commit(tenant_id, sha) do
    query =
      from(c in Commit,
        where: c.tenant_id == ^tenant_id and c.sha == ^sha
      )

    case Repo.one(query) do
      nil -> {:error, :not_found}
      commit -> {:ok, Commit.to_storage_format(commit)}
    end
  end

  # Reference operations

  @impl Levee.Storage.Behaviour
  def create_ref(tenant_id, ref_path, sha) do
    attrs = %{
      tenant_id: tenant_id,
      ref_path: ref_path,
      sha: sha
    }

    case %Ref{} |> Ref.changeset(attrs) |> Repo.insert() do
      {:ok, ref} ->
        {:ok, Ref.to_storage_format(ref)}

      {:error, %Ecto.Changeset{errors: errors}} ->
        if Keyword.has_key?(errors, :tenant_id) || Keyword.has_key?(errors, :ref_path) do
          {:error, :already_exists}
        else
          {:error, errors}
        end
    end
  end

  @impl Levee.Storage.Behaviour
  def get_ref(tenant_id, ref_path) do
    query =
      from(r in Ref,
        where: r.tenant_id == ^tenant_id and r.ref_path == ^ref_path
      )

    case Repo.one(query) do
      nil -> {:error, :not_found}
      ref -> {:ok, Ref.to_storage_format(ref)}
    end
  end

  @impl Levee.Storage.Behaviour
  def list_refs(tenant_id) do
    query =
      from(r in Ref,
        where: r.tenant_id == ^tenant_id
      )

    refs =
      Repo.all(query)
      |> Enum.map(&Ref.to_storage_format/1)

    {:ok, refs}
  end

  @impl Levee.Storage.Behaviour
  def update_ref(tenant_id, ref_path, sha) do
    query =
      from(r in Ref,
        where: r.tenant_id == ^tenant_id and r.ref_path == ^ref_path
      )

    case Repo.one(query) do
      nil ->
        {:error, :not_found}

      ref ->
        ref
        |> Ref.changeset(%{sha: sha})
        |> Repo.update()
        |> case do
          {:ok, updated} -> {:ok, Ref.to_storage_format(updated)}
          {:error, changeset} -> {:error, changeset.errors}
        end
    end
  end

  # Summary operations

  @impl Levee.Storage.Behaviour
  def store_summary(tenant_id, document_id, summary) do
    attrs = %{
      tenant_id: tenant_id,
      document_id: document_id,
      sequence_number: summary.sequence_number,
      handle: summary.handle,
      tree_sha: summary.tree_sha,
      commit_sha: summary.commit_sha,
      parent_handle: summary.parent_handle,
      message: summary.message
    }

    case %Summary{} |> Summary.changeset(attrs) |> Repo.insert() do
      {:ok, stored} ->
        {:ok, Summary.to_storage_format(stored)}

      {:error, changeset} ->
        {:error, changeset.errors}
    end
  end

  @impl Levee.Storage.Behaviour
  def get_summary(tenant_id, document_id, handle) do
    query =
      from(s in Summary,
        where:
          s.tenant_id == ^tenant_id and
            s.document_id == ^document_id and
            s.handle == ^handle
      )

    case Repo.one(query) do
      nil -> {:error, :not_found}
      summary -> {:ok, Summary.to_storage_format(summary)}
    end
  end

  @impl Levee.Storage.Behaviour
  def get_latest_summary(tenant_id, document_id) do
    query =
      from(s in Summary,
        where: s.tenant_id == ^tenant_id and s.document_id == ^document_id,
        order_by: [desc: s.sequence_number],
        limit: 1
      )

    case Repo.one(query) do
      nil -> {:error, :not_found}
      summary -> {:ok, Summary.to_storage_format(summary)}
    end
  end

  @impl Levee.Storage.Behaviour
  def list_summaries(tenant_id, document_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    from_sn = Keyword.get(opts, :from_sequence_number, 0)

    query =
      from(s in Summary,
        where:
          s.tenant_id == ^tenant_id and
            s.document_id == ^document_id and
            s.sequence_number >= ^from_sn,
        order_by: [asc: s.sequence_number],
        limit: ^limit
      )

    summaries =
      Repo.all(query)
      |> Enum.map(&Summary.to_storage_format/1)

    {:ok, summaries}
  end

  # Helper functions

  defp compute_sha256(content) do
    :crypto.hash(:sha256, content)
    |> Base.encode16(case: :lower)
  end
end
