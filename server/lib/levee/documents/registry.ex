defmodule Levee.Documents.Registry do
  @moduledoc """
  Registry for document sessions.

  Provides process lookup and creation for document sessions,
  keyed by {tenant_id, document_id}.

  This module does not maintain state - it wraps the Elixir Registry
  and DynamicSupervisor for session management.
  """

  alias Levee.Documents.Session

  @doc """
  Get an existing session or create a new one for the given tenant/document.
  """
  def get_or_create_session(tenant_id, document_id) do
    key = {tenant_id, document_id}

    case Registry.lookup(Levee.SessionRegistry, key) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
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
  Get an existing session. Returns `{:error, :not_found}` if not found.
  """
  def get_session(tenant_id, document_id) do
    key = {tenant_id, document_id}

    case Registry.lookup(Levee.SessionRegistry, key) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end
end
