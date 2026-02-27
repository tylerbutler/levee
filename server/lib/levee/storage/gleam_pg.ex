defmodule Levee.Storage.GleamPG do
  @moduledoc """
  PostgreSQL storage backend implemented in Gleam via the levee_storage package.

  This module bridges the Elixir `Levee.Storage.Behaviour` interface to
  the Gleam `levee_storage` PostgreSQL implementation using gleam_pgo.

  Phase 1: Stub implementation — all operations return `{:error, :not_implemented}`.
  """

  use GenServer

  @behaviour Levee.Storage.Behaviour

  # Gleam module for the PG backend
  @gleam_pg :levee_storage@pg

  @compile {:no_warn_undefined,
            [
              :levee_storage,
              :levee_storage@pg,
              :levee_storage@pg_pool,
              :levee_storage@types
            ]}

  # ---------------------------------------------------------------------------
  # GenServer (owns the PG connection pool)
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(opts) do
    database_url =
      Keyword.get(opts, :database_url) ||
        Application.get_env(:levee, :database_url) ||
        System.get_env("DATABASE_URL")

    case database_url do
      nil ->
        # No DATABASE_URL configured — start with nil connection (will fail on queries)
        :persistent_term.put(:levee_storage_pg_conn, nil)
        {:ok, %{conn: nil}}

      url ->
        # Parse URL and start pog connection pool via the Gleam module
        gleam_pg = :levee_storage@pg_pool
        conn = gleam_pg.start_from_url(url)
        :persistent_term.put(:levee_storage_pg_conn, conn)

        # Run migrations
        run_migrations(conn)

        {:ok, %{conn: conn}}
    end
  end

  defp run_migrations(conn) do
    migration_file =
      Path.join(:code.priv_dir(:levee), "repo/migrations/001_create_storage_tables.sql")

    if File.exists?(migration_file) do
      sql = File.read!(migration_file)

      # Execute each statement separately (split on semicolons at end of line)
      sql
      |> String.split(~r/;\s*\n/, trim: true)
      |> Enum.each(fn stmt ->
        stmt = String.trim(stmt)

        if stmt != "" do
          :levee_storage@pg_pool.execute_raw(conn, stmt)
        end
      end)
    end
  end

  defp conn do
    :persistent_term.get(:levee_storage_pg_conn)
  end

  # ---------------------------------------------------------------------------
  # Document operations
  # ---------------------------------------------------------------------------

  @impl Levee.Storage.Behaviour
  def create_document(tenant_id, document_id, params) do
    sn = params[:sequence_number] || 0

    case @gleam_pg.create_document(conn(), tenant_id, document_id, sn) do
      {:ok, doc} -> {:ok, gleam_document_to_map(doc)}
      {:error, :already_exists} -> {:error, :already_exists}
      {:error, {:storage_error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Levee.Storage.Behaviour
  def get_document(tenant_id, document_id) do
    case @gleam_pg.get_document(conn(), tenant_id, document_id) do
      {:ok, doc} -> {:ok, gleam_document_to_map(doc)}
      {:error, :not_found} -> {:error, :not_found}
      {:error, {:storage_error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Levee.Storage.Behaviour
  def update_document_sequence(tenant_id, document_id, sequence_number) do
    case @gleam_pg.update_document_sequence(conn(), tenant_id, document_id, sequence_number) do
      {:ok, doc} -> {:ok, gleam_document_to_map(doc)}
      {:error, :not_found} -> {:error, :not_found}
      {:error, {:storage_error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Delta operations
  # ---------------------------------------------------------------------------

  @impl Levee.Storage.Behaviour
  def store_delta(tenant_id, document_id, delta) do
    gleam_delta = elixir_delta_to_gleam(delta)

    case @gleam_pg.store_delta(conn(), tenant_id, document_id, gleam_delta) do
      {:ok, stored} -> {:ok, gleam_delta_to_map(stored)}
      {:error, {:storage_error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Levee.Storage.Behaviour
  def get_deltas(tenant_id, document_id, opts \\ []) do
    from_sn = Keyword.get(opts, :from, -1)
    to_sn = Keyword.get(opts, :to, nil)
    limit = Keyword.get(opts, :limit, 2000)

    gleam_to_sn = if to_sn, do: {:some, to_sn}, else: :none

    case @gleam_pg.get_deltas(conn(), tenant_id, document_id, from_sn, gleam_to_sn, limit) do
      {:ok, deltas} -> {:ok, Enum.map(deltas, &gleam_delta_to_map/1)}
      {:error, {:storage_error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Blob operations
  # ---------------------------------------------------------------------------

  @impl Levee.Storage.Behaviour
  def create_blob(tenant_id, content) when is_binary(content) do
    case @gleam_pg.create_blob(conn(), tenant_id, content) do
      {:ok, blob} -> {:ok, gleam_blob_to_map(blob)}
      {:error, {:storage_error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Levee.Storage.Behaviour
  def get_blob(tenant_id, sha) do
    case @gleam_pg.get_blob(conn(), tenant_id, sha) do
      {:ok, blob} -> {:ok, gleam_blob_to_map(blob)}
      {:error, :not_found} -> {:error, :not_found}
      {:error, {:storage_error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Tree operations
  # ---------------------------------------------------------------------------

  @impl Levee.Storage.Behaviour
  def create_tree(tenant_id, entries) do
    gleam_entries = Enum.map(entries, &elixir_tree_entry_to_gleam/1)

    case @gleam_pg.create_tree(conn(), tenant_id, gleam_entries) do
      {:ok, tree} -> {:ok, gleam_tree_to_map(tree)}
      {:error, {:storage_error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Levee.Storage.Behaviour
  def get_tree(tenant_id, sha, opts \\ []) do
    recursive = Keyword.get(opts, :recursive, false)

    case @gleam_pg.get_tree(conn(), tenant_id, sha, recursive) do
      {:ok, tree} -> {:ok, gleam_tree_to_map(tree)}
      {:error, :not_found} -> {:error, :not_found}
      {:error, {:storage_error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Commit operations
  # ---------------------------------------------------------------------------

  @impl Levee.Storage.Behaviour
  def create_commit(tenant_id, params) do
    tree_sha = params["tree"]
    parents = params["parents"] || []
    message = wrap_option(params["message"])
    author = params["author"]
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    committer =
      params["committer"] ||
        %{
          "name" => "Levee",
          "email" => "server@fluid.local",
          "date" => now
        }

    case @gleam_pg.create_commit(
           conn(),
           tenant_id,
           tree_sha,
           parents,
           message,
           author,
           committer
         ) do
      {:ok, commit} -> {:ok, gleam_commit_to_map(commit)}
      {:error, {:storage_error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Levee.Storage.Behaviour
  def get_commit(tenant_id, sha) do
    case @gleam_pg.get_commit(conn(), tenant_id, sha) do
      {:ok, commit} -> {:ok, gleam_commit_to_map(commit)}
      {:error, :not_found} -> {:error, :not_found}
      {:error, {:storage_error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Reference operations
  # ---------------------------------------------------------------------------

  @impl Levee.Storage.Behaviour
  def create_ref(tenant_id, ref_path, sha) do
    case @gleam_pg.create_ref(conn(), tenant_id, ref_path, sha) do
      {:ok, r} -> {:ok, gleam_ref_to_map(r)}
      {:error, :already_exists} -> {:error, :already_exists}
      {:error, {:storage_error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Levee.Storage.Behaviour
  def get_ref(tenant_id, ref_path) do
    case @gleam_pg.get_ref(conn(), tenant_id, ref_path) do
      {:ok, r} -> {:ok, gleam_ref_to_map(r)}
      {:error, :not_found} -> {:error, :not_found}
      {:error, {:storage_error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Levee.Storage.Behaviour
  def list_refs(tenant_id) do
    case @gleam_pg.list_refs(conn(), tenant_id) do
      {:ok, refs} -> {:ok, Enum.map(refs, &gleam_ref_to_map/1)}
      {:error, {:storage_error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Levee.Storage.Behaviour
  def update_ref(tenant_id, ref_path, sha) do
    case @gleam_pg.update_ref(conn(), tenant_id, ref_path, sha) do
      {:ok, r} -> {:ok, gleam_ref_to_map(r)}
      {:error, :not_found} -> {:error, :not_found}
      {:error, {:storage_error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Summary operations
  # ---------------------------------------------------------------------------

  @impl Levee.Storage.Behaviour
  def store_summary(tenant_id, document_id, summary) do
    gleam_summary = elixir_summary_to_gleam(summary)

    case @gleam_pg.store_summary(conn(), tenant_id, document_id, gleam_summary) do
      {:ok, stored} -> {:ok, gleam_summary_to_map(stored)}
      {:error, {:storage_error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Levee.Storage.Behaviour
  def get_summary(tenant_id, document_id, handle) do
    case @gleam_pg.get_summary(conn(), tenant_id, document_id, handle) do
      {:ok, s} -> {:ok, gleam_summary_to_map(s)}
      {:error, :not_found} -> {:error, :not_found}
      {:error, {:storage_error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Levee.Storage.Behaviour
  def get_latest_summary(tenant_id, document_id) do
    case @gleam_pg.get_latest_summary(conn(), tenant_id, document_id) do
      {:ok, s} -> {:ok, gleam_summary_to_map(s)}
      {:error, :not_found} -> {:error, :not_found}
      {:error, {:storage_error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Levee.Storage.Behaviour
  def list_summaries(tenant_id, document_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    from_sn = Keyword.get(opts, :from_sequence_number, 0)

    case @gleam_pg.list_summaries(conn(), tenant_id, document_id, from_sn, limit) do
      {:ok, summaries} -> {:ok, Enum.map(summaries, &gleam_summary_to_map/1)}
      {:error, {:storage_error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Gleam tuple → Elixir map converters
  # ---------------------------------------------------------------------------

  defp gleam_document_to_map({:document, id, tenant_id, sn, created_at, updated_at}) do
    %{
      id: id,
      tenant_id: tenant_id,
      sequence_number: sn,
      created_at: created_at,
      updated_at: updated_at
    }
  end

  defp gleam_document_to_map(%{} = map) do
    %{
      id: Map.get(map, :id),
      tenant_id: Map.get(map, :tenant_id),
      sequence_number: Map.get(map, :sequence_number),
      created_at: Map.get(map, :created_at),
      updated_at: Map.get(map, :updated_at)
    }
  end

  defp gleam_delta_to_map({:delta, sn, client_id, csn, rsn, msn, type, contents, metadata, ts}) do
    %{
      sequence_number: sn,
      client_id: unwrap_option(client_id),
      client_sequence_number: csn,
      reference_sequence_number: rsn,
      minimum_sequence_number: msn,
      type: type,
      contents: contents,
      metadata: metadata,
      timestamp: ts
    }
  end

  defp gleam_blob_to_map({:blob, sha, content, size}) do
    %{sha: sha, content: content, size: size}
  end

  defp gleam_tree_to_map({:tree, sha, entries}) do
    %{
      sha: sha,
      tree: Enum.map(entries, &gleam_tree_entry_to_map/1)
    }
  end

  defp gleam_tree_entry_to_map({:tree_entry, path, mode, sha, entry_type}) do
    %{path: path, mode: mode, sha: sha, type: entry_type}
  end

  defp gleam_commit_to_map({:commit, sha, tree, parents, message, author, committer}) do
    %{
      sha: sha,
      tree: tree,
      parents: parents,
      message: unwrap_option(message),
      author: author,
      committer: committer
    }
  end

  defp gleam_ref_to_map({:ref, ref_path, sha}) do
    %{ref: ref_path, sha: sha}
  end

  defp gleam_summary_to_map(
         {:summary, handle, tenant_id, document_id, sn, tree_sha, commit_sha, parent_handle,
          message, created_at}
       ) do
    %{
      handle: handle,
      tenant_id: tenant_id,
      document_id: document_id,
      sequence_number: sn,
      tree_sha: tree_sha,
      commit_sha: unwrap_option(commit_sha),
      parent_handle: unwrap_option(parent_handle),
      message: unwrap_option(message),
      created_at: created_at
    }
  end

  # ---------------------------------------------------------------------------
  # Elixir map → Gleam tuple converters
  # ---------------------------------------------------------------------------

  defp elixir_delta_to_gleam(delta) do
    {:delta, delta.sequence_number, wrap_option(delta.client_id), delta.client_sequence_number,
     delta.reference_sequence_number, delta.minimum_sequence_number, delta.type, delta.contents,
     delta.metadata, delta.timestamp}
  end

  defp elixir_tree_entry_to_gleam(entry) do
    path = entry[:path] || entry["path"]
    mode = entry[:mode] || entry["mode"]
    sha = entry[:sha] || entry["sha"]
    type = entry[:type] || entry["type"]
    {:tree_entry, path, mode, sha, type}
  end

  defp elixir_summary_to_gleam(summary) do
    {:summary, summary.handle, Map.get(summary, :tenant_id, ""),
     Map.get(summary, :document_id, ""), summary.sequence_number, summary.tree_sha,
     wrap_option(Map.get(summary, :commit_sha)), wrap_option(Map.get(summary, :parent_handle)),
     wrap_option(Map.get(summary, :message)), Map.get(summary, :created_at)}
  end

  # Gleam Option helpers
  defp wrap_option(nil), do: :none
  defp wrap_option(value), do: {:some, value}

  defp unwrap_option(:none), do: nil
  defp unwrap_option({:some, value}), do: value
  defp unwrap_option(value), do: value
end
