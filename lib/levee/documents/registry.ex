defmodule Levee.Documents.Registry do
  @moduledoc """
  Registry for document sessions.

  Provides process lookup and creation for document sessions,
  keyed by {tenant_id, document_id}.
  """

  use GenServer

  alias Levee.Documents.Session

  @registry_name __MODULE__

  # Client API

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: @registry_name)
  end

  @doc """
  Get an existing session or create a new one for the given tenant/document.
  """
  def get_or_create_session(tenant_id, document_id) do
    key = {tenant_id, document_id}

    case Registry.lookup(Levee.SessionRegistry, key) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        # Start a new session under the DynamicSupervisor
        case DynamicSupervisor.start_child(
               Levee.Documents.Supervisor,
               {Session, {tenant_id, document_id}}
             ) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc """
  Get an existing session, returns nil if not found.
  """
  def get_session(tenant_id, document_id) do
    key = {tenant_id, document_id}

    case Registry.lookup(Levee.SessionRegistry, key) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  # Server callbacks

  @impl true
  def init(state) do
    {:ok, state}
  end
end
