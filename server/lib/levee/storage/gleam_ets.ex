defmodule Levee.Storage.GleamETS do
  @moduledoc """
  Gleam-based ETS storage implementation.

  Delegates storage operations to the Gleam levee_storage ETS backend.
  This GenServer owns the ETS tables and initializes them on startup.
  """

  use GenServer

  @behaviour Levee.Storage.Behaviour

  @gleam_ets :levee_storage_ets_backend
  @compile {:no_warn_undefined, [@gleam_ets]}

  @max_deltas_per_request 2000

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # Document operations

  @impl Levee.Storage.Behaviour
  def create_document(tenant_id, document_id, params) do
    @gleam_ets.create_document(tenant_id, document_id, params)
  end

  @impl Levee.Storage.Behaviour
  def get_document(tenant_id, document_id) do
    @gleam_ets.get_document(tenant_id, document_id)
  end

  @impl Levee.Storage.Behaviour
  def update_document_sequence(tenant_id, document_id, sequence_number) do
    @gleam_ets.update_document_sequence(tenant_id, document_id, sequence_number)
  end

  # Delta operations

  @impl Levee.Storage.Behaviour
  def store_delta(tenant_id, document_id, delta) do
    @gleam_ets.store_delta(tenant_id, document_id, delta)
  end

  @impl Levee.Storage.Behaviour
  def get_deltas(tenant_id, document_id, opts \\ []) do
    opts_map = Map.new(opts)
    @gleam_ets.get_deltas(tenant_id, document_id, opts_map, @max_deltas_per_request)
  end

  # Blob operations

  @impl Levee.Storage.Behaviour
  def create_blob(tenant_id, content) do
    @gleam_ets.create_blob(tenant_id, content)
  end

  @impl Levee.Storage.Behaviour
  def get_blob(tenant_id, sha) do
    @gleam_ets.get_blob(tenant_id, sha)
  end

  # Tree operations

  @impl Levee.Storage.Behaviour
  def create_tree(tenant_id, entries) do
    @gleam_ets.create_tree(tenant_id, entries)
  end

  @impl Levee.Storage.Behaviour
  def get_tree(tenant_id, sha, opts \\ []) do
    recursive = Keyword.get(opts, :recursive, false)
    @gleam_ets.get_tree(tenant_id, sha, recursive)
  end

  # Commit operations

  @impl Levee.Storage.Behaviour
  def create_commit(tenant_id, params) do
    @gleam_ets.create_commit(tenant_id, params)
  end

  @impl Levee.Storage.Behaviour
  def get_commit(tenant_id, sha) do
    @gleam_ets.get_commit(tenant_id, sha)
  end

  # Reference operations

  @impl Levee.Storage.Behaviour
  def create_ref(tenant_id, ref_path, sha) do
    @gleam_ets.create_ref(tenant_id, ref_path, sha)
  end

  @impl Levee.Storage.Behaviour
  def get_ref(tenant_id, ref_path) do
    @gleam_ets.get_ref(tenant_id, ref_path)
  end

  @impl Levee.Storage.Behaviour
  def list_refs(tenant_id) do
    @gleam_ets.list_refs(tenant_id)
  end

  @impl Levee.Storage.Behaviour
  def update_ref(tenant_id, ref_path, sha) do
    @gleam_ets.update_ref(tenant_id, ref_path, sha)
  end

  # Summary operations

  @impl Levee.Storage.Behaviour
  def store_summary(tenant_id, document_id, summary) do
    @gleam_ets.store_summary(tenant_id, document_id, summary)
  end

  @impl Levee.Storage.Behaviour
  def get_summary(tenant_id, document_id, handle) do
    @gleam_ets.get_summary(tenant_id, document_id, handle)
  end

  @impl Levee.Storage.Behaviour
  def get_latest_summary(tenant_id, document_id) do
    @gleam_ets.get_latest_summary(tenant_id, document_id)
  end

  @impl Levee.Storage.Behaviour
  def list_summaries(tenant_id, document_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    from_sn = Keyword.get(opts, :from_sequence_number, 0)
    @gleam_ets.list_summaries(tenant_id, document_id, from_sn, limit)
  end

  # GenServer callbacks

  @impl GenServer
  def init(_opts) do
    @gleam_ets.init_tables()
    {:ok, %{}}
  end
end
