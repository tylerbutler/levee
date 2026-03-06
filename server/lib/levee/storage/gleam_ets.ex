defmodule Levee.Storage.GleamETS do
  @moduledoc """
  Persistent ETS storage backend implemented in Gleam via the levee_storage package.

  This module bridges the Elixir `Levee.Storage.Behaviour` interface to
  the Gleam `levee_storage` ETS implementation using shelf for persistent
  ETS tables backed by DETS.

  Data is stored in-memory via ETS for fast reads and persisted to DETS
  files on disk. Tables are saved on terminate and periodically via
  a configurable save interval.
  """

  use GenServer

  @behaviour Levee.Storage.Behaviour

  # Gleam modules compile to these atoms
  @gleam_ets :levee_storage@ets
  @interop :levee_storage@interop

  @compile {:no_warn_undefined,
            [
              :levee_storage,
              :levee_storage@ets,
              :levee_storage@interop,
              :levee_storage@types
            ]}

  # Save to disk every 30 seconds
  @save_interval_ms 30_000

  # ---------------------------------------------------------------------------
  # GenServer (owns the ETS/DETS tables)
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    data_dir = data_dir()
    File.mkdir_p!(data_dir)

    tables = @gleam_ets.init(data_dir)
    # Store tables handle in persistent_term for fast access from any process
    :persistent_term.put(:levee_storage_tables, tables)

    # Schedule periodic saves
    schedule_save()

    {:ok, %{tables: tables}}
  end

  @impl true
  def terminate(_reason, state) do
    # Save and close all tables on shutdown
    @gleam_ets.close(state.tables)
    :persistent_term.erase(:levee_storage_tables)
  end

  @impl true
  def handle_info(:periodic_save, state) do
    @gleam_ets.save(state.tables)
    schedule_save()
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp schedule_save do
    Process.send_after(self(), :periodic_save, @save_interval_ms)
  end

  defp data_dir do
    Application.get_env(:levee, :storage_data_dir, default_data_dir())
  end

  defp default_data_dir do
    Path.join(File.cwd!(), "priv/storage/dets")
  end

  defp tables do
    :persistent_term.get(:levee_storage_tables)
  end

  # ---------------------------------------------------------------------------
  # Document operations
  # ---------------------------------------------------------------------------

  @impl Levee.Storage.Behaviour
  def create_document(tenant_id, document_id, params) do
    sn = params[:sequence_number] || 0

    case @gleam_ets.create_document(tables(), tenant_id, document_id, sn) do
      {:ok, doc} -> {:ok, @interop.document_to_map(doc)}
      {:error, :already_exists} -> {:error, :already_exists}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Levee.Storage.Behaviour
  def get_document(tenant_id, document_id) do
    case @gleam_ets.get_document(tables(), tenant_id, document_id) do
      {:ok, doc} -> {:ok, @interop.document_to_map(doc)}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @impl Levee.Storage.Behaviour
  def update_document_sequence(tenant_id, document_id, sequence_number) do
    case @gleam_ets.update_document_sequence(tables(), tenant_id, document_id, sequence_number) do
      {:ok, doc} -> {:ok, @interop.document_to_map(doc)}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  # ---------------------------------------------------------------------------
  # Delta operations
  # ---------------------------------------------------------------------------

  @impl Levee.Storage.Behaviour
  def store_delta(tenant_id, document_id, delta) do
    gleam_delta = @interop.map_to_delta(delta)

    case @gleam_ets.store_delta(tables(), tenant_id, document_id, gleam_delta) do
      {:ok, stored} -> {:ok, @interop.delta_to_map(stored)}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Levee.Storage.Behaviour
  def get_deltas(tenant_id, document_id, opts \\ []) do
    from_sn = Keyword.get(opts, :from, -1)
    to_sn = Keyword.get(opts, :to, nil)
    limit = Keyword.get(opts, :limit, 2000)

    gleam_to_sn = if to_sn, do: {:some, to_sn}, else: :none

    case @gleam_ets.get_deltas(tables(), tenant_id, document_id, from_sn, gleam_to_sn, limit) do
      {:ok, deltas} -> {:ok, Enum.map(deltas, &@interop.delta_to_map/1)}
    end
  end

  # ---------------------------------------------------------------------------
  # Blob operations
  # ---------------------------------------------------------------------------

  @impl Levee.Storage.Behaviour
  def create_blob(tenant_id, content) when is_binary(content) do
    case @gleam_ets.create_blob(tables(), tenant_id, content) do
      {:ok, blob} -> {:ok, @interop.blob_to_map(blob)}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Levee.Storage.Behaviour
  def get_blob(tenant_id, sha) do
    case @gleam_ets.get_blob(tables(), tenant_id, sha) do
      {:ok, blob} -> {:ok, @interop.blob_to_map(blob)}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  # ---------------------------------------------------------------------------
  # Tree operations
  # ---------------------------------------------------------------------------

  @impl Levee.Storage.Behaviour
  def create_tree(tenant_id, entries) do
    gleam_entries = Enum.map(entries, &@interop.map_to_tree_entry/1)

    case @gleam_ets.create_tree(tables(), tenant_id, gleam_entries) do
      {:ok, tree} -> {:ok, @interop.tree_to_map(tree)}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Levee.Storage.Behaviour
  def get_tree(tenant_id, sha, opts \\ []) do
    recursive = Keyword.get(opts, :recursive, false)

    case @gleam_ets.get_tree(tables(), tenant_id, sha, recursive) do
      {:ok, tree} -> {:ok, @interop.tree_to_map(tree)}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  # ---------------------------------------------------------------------------
  # Commit operations
  # ---------------------------------------------------------------------------

  @impl Levee.Storage.Behaviour
  def create_commit(tenant_id, params) do
    tree_sha = params["tree"]
    parents = params["parents"] || []
    message = if params["message"], do: {:some, params["message"]}, else: :none
    author = params["author"]
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    committer =
      params["committer"] ||
        %{
          "name" => "Levee",
          "email" => "server@fluid.local",
          "date" => now
        }

    case @gleam_ets.create_commit(
           tables(),
           tenant_id,
           tree_sha,
           parents,
           message,
           author,
           committer
         ) do
      {:ok, commit} -> {:ok, @interop.commit_to_map(commit)}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Levee.Storage.Behaviour
  def get_commit(tenant_id, sha) do
    case @gleam_ets.get_commit(tables(), tenant_id, sha) do
      {:ok, commit} -> {:ok, @interop.commit_to_map(commit)}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  # ---------------------------------------------------------------------------
  # Reference operations
  # ---------------------------------------------------------------------------

  @impl Levee.Storage.Behaviour
  def create_ref(tenant_id, ref_path, sha) do
    case @gleam_ets.create_ref(tables(), tenant_id, ref_path, sha) do
      {:ok, r} -> {:ok, @interop.ref_to_map(r)}
      {:error, :already_exists} -> {:error, :already_exists}
    end
  end

  @impl Levee.Storage.Behaviour
  def get_ref(tenant_id, ref_path) do
    case @gleam_ets.get_ref(tables(), tenant_id, ref_path) do
      {:ok, r} -> {:ok, @interop.ref_to_map(r)}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @impl Levee.Storage.Behaviour
  def list_refs(tenant_id) do
    case @gleam_ets.list_refs(tables(), tenant_id) do
      {:ok, refs} -> {:ok, Enum.map(refs, &@interop.ref_to_map/1)}
    end
  end

  @impl Levee.Storage.Behaviour
  def update_ref(tenant_id, ref_path, sha) do
    case @gleam_ets.update_ref(tables(), tenant_id, ref_path, sha) do
      {:ok, r} -> {:ok, @interop.ref_to_map(r)}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  # ---------------------------------------------------------------------------
  # Summary operations
  # ---------------------------------------------------------------------------

  @impl Levee.Storage.Behaviour
  def store_summary(tenant_id, document_id, summary) do
    gleam_summary = @interop.map_to_summary(summary)

    case @gleam_ets.store_summary(tables(), tenant_id, document_id, gleam_summary) do
      {:ok, stored} -> {:ok, @interop.summary_to_map(stored)}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Levee.Storage.Behaviour
  def get_summary(tenant_id, document_id, handle) do
    case @gleam_ets.get_summary(tables(), tenant_id, document_id, handle) do
      {:ok, s} -> {:ok, @interop.summary_to_map(s)}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @impl Levee.Storage.Behaviour
  def get_latest_summary(tenant_id, document_id) do
    case @gleam_ets.get_latest_summary(tables(), tenant_id, document_id) do
      {:ok, s} -> {:ok, @interop.summary_to_map(s)}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @impl Levee.Storage.Behaviour
  def list_summaries(tenant_id, document_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    from_sn = Keyword.get(opts, :from_sequence_number, 0)

    case @gleam_ets.list_summaries(tables(), tenant_id, document_id, from_sn, limit) do
      {:ok, summaries} -> {:ok, Enum.map(summaries, &@interop.summary_to_map/1)}
    end
  end
end
