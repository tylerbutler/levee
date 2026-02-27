defmodule Levee.Storage do
  @moduledoc """
  Dynamic dispatch wrapper for storage backends.

  Delegates all storage operations to the configured backend module.
  The backend is configured via:

      config :levee, :storage_backend, Levee.Storage.GleamETS

  All functions delegate to the configured backend module.
  """

  @behaviour Levee.Storage.Behaviour

  @doc """
  Get the currently configured storage backend module.
  """
  def backend do
    Application.get_env(:levee, :storage_backend, Levee.Storage.GleamETS)
  end

  # Document operations

  @impl Levee.Storage.Behaviour
  def create_document(tenant_id, document_id, params) do
    backend().create_document(tenant_id, document_id, params)
  end

  @impl Levee.Storage.Behaviour
  def get_document(tenant_id, document_id) do
    backend().get_document(tenant_id, document_id)
  end

  @impl Levee.Storage.Behaviour
  def update_document_sequence(tenant_id, document_id, sequence_number) do
    backend().update_document_sequence(tenant_id, document_id, sequence_number)
  end

  # Delta operations

  @impl Levee.Storage.Behaviour
  def store_delta(tenant_id, document_id, delta) do
    backend().store_delta(tenant_id, document_id, delta)
  end

  @impl Levee.Storage.Behaviour
  def get_deltas(tenant_id, document_id, opts \\ []) do
    backend().get_deltas(tenant_id, document_id, opts)
  end

  # Blob operations

  @impl Levee.Storage.Behaviour
  def create_blob(tenant_id, content) do
    backend().create_blob(tenant_id, content)
  end

  @impl Levee.Storage.Behaviour
  def get_blob(tenant_id, sha) do
    backend().get_blob(tenant_id, sha)
  end

  # Tree operations

  @impl Levee.Storage.Behaviour
  def create_tree(tenant_id, entries) do
    backend().create_tree(tenant_id, entries)
  end

  @impl Levee.Storage.Behaviour
  def get_tree(tenant_id, sha, opts \\ []) do
    backend().get_tree(tenant_id, sha, opts)
  end

  # Commit operations

  @impl Levee.Storage.Behaviour
  def create_commit(tenant_id, params) do
    backend().create_commit(tenant_id, params)
  end

  @impl Levee.Storage.Behaviour
  def get_commit(tenant_id, sha) do
    backend().get_commit(tenant_id, sha)
  end

  # Reference operations

  @impl Levee.Storage.Behaviour
  def create_ref(tenant_id, ref_path, sha) do
    backend().create_ref(tenant_id, ref_path, sha)
  end

  @impl Levee.Storage.Behaviour
  def get_ref(tenant_id, ref_path) do
    backend().get_ref(tenant_id, ref_path)
  end

  @impl Levee.Storage.Behaviour
  def list_refs(tenant_id) do
    backend().list_refs(tenant_id)
  end

  @impl Levee.Storage.Behaviour
  def update_ref(tenant_id, ref_path, sha) do
    backend().update_ref(tenant_id, ref_path, sha)
  end

  # Summary operations

  @impl Levee.Storage.Behaviour
  def store_summary(tenant_id, document_id, summary) do
    backend().store_summary(tenant_id, document_id, summary)
  end

  @impl Levee.Storage.Behaviour
  def get_summary(tenant_id, document_id, handle) do
    backend().get_summary(tenant_id, document_id, handle)
  end

  @impl Levee.Storage.Behaviour
  def get_latest_summary(tenant_id, document_id) do
    backend().get_latest_summary(tenant_id, document_id)
  end

  @impl Levee.Storage.Behaviour
  def list_summaries(tenant_id, document_id, opts \\ []) do
    backend().list_summaries(tenant_id, document_id, opts)
  end
end
