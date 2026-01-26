defmodule FluidServer.Storage.ETS do
  @moduledoc """
  ETS-based storage implementation for the Fluid Framework server.

  This is an in-memory storage backend suitable for development and testing.
  Data is not persisted across restarts.

  Uses multiple ETS tables:
  - :fluid_documents - Document metadata
  - :fluid_deltas - Sequenced operations
  - :fluid_blobs - Git blob objects
  - :fluid_trees - Git tree objects
  - :fluid_commits - Git commit objects
  - :fluid_refs - Git references
  """

  use GenServer

  @behaviour FluidServer.Storage.Behaviour

  @max_deltas_per_request 2000

  # Table names
  @documents_table :fluid_documents
  @deltas_table :fluid_deltas
  @blobs_table :fluid_blobs
  @trees_table :fluid_trees
  @commits_table :fluid_commits
  @refs_table :fluid_refs

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # Document operations

  @impl FluidServer.Storage.Behaviour
  def create_document(tenant_id, document_id, params) do
    now = DateTime.utc_now()

    document = %{
      id: document_id,
      tenant_id: tenant_id,
      sequence_number: params[:sequence_number] || 0,
      created_at: now,
      updated_at: now
    }

    key = {tenant_id, document_id}

    case :ets.insert_new(@documents_table, {key, document}) do
      true -> {:ok, document}
      false -> {:error, :already_exists}
    end
  end

  @impl FluidServer.Storage.Behaviour
  def get_document(tenant_id, document_id) do
    key = {tenant_id, document_id}

    case :ets.lookup(@documents_table, key) do
      [{^key, document}] -> {:ok, document}
      [] -> {:error, :not_found}
    end
  end

  @impl FluidServer.Storage.Behaviour
  def update_document_sequence(tenant_id, document_id, sequence_number) do
    key = {tenant_id, document_id}

    case :ets.lookup(@documents_table, key) do
      [{^key, document}] ->
        updated = %{document | sequence_number: sequence_number, updated_at: DateTime.utc_now()}
        :ets.insert(@documents_table, {key, updated})
        {:ok, updated}

      [] ->
        {:error, :not_found}
    end
  end

  # Delta operations

  @impl FluidServer.Storage.Behaviour
  def store_delta(tenant_id, document_id, delta) do
    # Key is {tenant_id, document_id, sequence_number} for ordered retrieval
    key = {tenant_id, document_id, delta.sequence_number}
    :ets.insert(@deltas_table, {key, delta})
    {:ok, delta}
  end

  @impl FluidServer.Storage.Behaviour
  def get_deltas(tenant_id, document_id, opts \\ []) do
    from_sn = Keyword.get(opts, :from, -1)
    to_sn = Keyword.get(opts, :to, nil)
    limit = min(Keyword.get(opts, :limit, @max_deltas_per_request), @max_deltas_per_request)

    # Match pattern for this document's deltas
    match_spec = [
      {
        {{tenant_id, document_id, :"$1"}, :"$2"},
        build_delta_guards(from_sn, to_sn),
        [:"$2"]
      }
    ]

    deltas =
      :ets.select(@deltas_table, match_spec)
      |> Enum.sort_by(& &1.sequence_number)
      |> Enum.take(limit)

    {:ok, deltas}
  end

  defp build_delta_guards(from_sn, nil) do
    [{:>, :"$1", from_sn}]
  end

  defp build_delta_guards(from_sn, to_sn) do
    [{:>, :"$1", from_sn}, {:<, :"$1", to_sn}]
  end

  # Blob operations

  @impl FluidServer.Storage.Behaviour
  def create_blob(tenant_id, content) when is_binary(content) do
    sha = compute_sha256(content)

    blob = %{
      sha: sha,
      content: content,
      size: byte_size(content)
    }

    key = {tenant_id, sha}
    :ets.insert(@blobs_table, {key, blob})
    {:ok, blob}
  end

  @impl FluidServer.Storage.Behaviour
  def get_blob(tenant_id, sha) do
    key = {tenant_id, sha}

    case :ets.lookup(@blobs_table, key) do
      [{^key, blob}] -> {:ok, blob}
      [] -> {:error, :not_found}
    end
  end

  # Tree operations

  @impl FluidServer.Storage.Behaviour
  def create_tree(tenant_id, entries) do
    # Serialize and hash the tree entries for the SHA
    tree_content = Jason.encode!(entries)
    sha = compute_sha256(tree_content)

    tree = %{
      sha: sha,
      tree: entries
    }

    key = {tenant_id, sha}
    :ets.insert(@trees_table, {key, tree})
    {:ok, tree}
  end

  @impl FluidServer.Storage.Behaviour
  def get_tree(tenant_id, sha, opts \\ []) do
    key = {tenant_id, sha}

    case :ets.lookup(@trees_table, key) do
      [{^key, tree}] ->
        if Keyword.get(opts, :recursive, false) do
          {:ok, expand_tree_recursive(tenant_id, tree)}
        else
          {:ok, tree}
        end

      [] ->
        {:error, :not_found}
    end
  end

  defp expand_tree_recursive(tenant_id, tree) do
    expanded_entries =
      Enum.flat_map(tree.tree, fn entry ->
        case entry.type do
          "tree" ->
            case get_tree(tenant_id, entry.sha, recursive: true) do
              {:ok, subtree} ->
                # Prefix paths with parent path
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

  @impl FluidServer.Storage.Behaviour
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

    commit = %{
      sha: sha,
      tree: params["tree"],
      parents: params["parents"] || [],
      message: params["message"],
      author: params["author"],
      committer: params["committer"] || %{
        "name" => "FluidServer",
        "email" => "server@fluid.local",
        "date" => now
      }
    }

    key = {tenant_id, sha}
    :ets.insert(@commits_table, {key, commit})
    {:ok, commit}
  end

  @impl FluidServer.Storage.Behaviour
  def get_commit(tenant_id, sha) do
    key = {tenant_id, sha}

    case :ets.lookup(@commits_table, key) do
      [{^key, commit}] -> {:ok, commit}
      [] -> {:error, :not_found}
    end
  end

  # Reference operations

  @impl FluidServer.Storage.Behaviour
  def create_ref(tenant_id, ref_path, sha) do
    ref = %{
      ref: ref_path,
      sha: sha
    }

    key = {tenant_id, ref_path}

    case :ets.insert_new(@refs_table, {key, ref}) do
      true -> {:ok, ref}
      false -> {:error, :already_exists}
    end
  end

  @impl FluidServer.Storage.Behaviour
  def get_ref(tenant_id, ref_path) do
    key = {tenant_id, ref_path}

    case :ets.lookup(@refs_table, key) do
      [{^key, ref}] -> {:ok, ref}
      [] -> {:error, :not_found}
    end
  end

  @impl FluidServer.Storage.Behaviour
  def list_refs(tenant_id) do
    # Match all refs for this tenant
    match_spec = [
      {
        {{tenant_id, :_}, :"$1"},
        [],
        [:"$1"]
      }
    ]

    refs = :ets.select(@refs_table, match_spec)
    {:ok, refs}
  end

  @impl FluidServer.Storage.Behaviour
  def update_ref(tenant_id, ref_path, sha) do
    key = {tenant_id, ref_path}

    case :ets.lookup(@refs_table, key) do
      [{^key, _ref}] ->
        updated_ref = %{ref: ref_path, sha: sha}
        :ets.insert(@refs_table, {key, updated_ref})
        {:ok, updated_ref}

      [] ->
        {:error, :not_found}
    end
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    # Create ETS tables
    :ets.new(@documents_table, [:set, :public, :named_table, read_concurrency: true])
    :ets.new(@deltas_table, [:ordered_set, :public, :named_table, read_concurrency: true])
    :ets.new(@blobs_table, [:set, :public, :named_table, read_concurrency: true])
    :ets.new(@trees_table, [:set, :public, :named_table, read_concurrency: true])
    :ets.new(@commits_table, [:set, :public, :named_table, read_concurrency: true])
    :ets.new(@refs_table, [:set, :public, :named_table, read_concurrency: true])

    {:ok, %{}}
  end

  # Helper functions

  defp compute_sha256(content) do
    :crypto.hash(:sha256, content)
    |> Base.encode16(case: :lower)
  end
end
