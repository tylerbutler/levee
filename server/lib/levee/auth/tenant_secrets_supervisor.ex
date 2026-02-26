defmodule Levee.Auth.TenantSecretsSupervisor do
  @moduledoc """
  Starts and registers the Gleam tenant secrets actor.
  Holds the actor Subject so Elixir callers can access it via `get_actor/0`.
  """
  use GenServer

  @compile {:no_warn_undefined, [:tenant_secrets]}

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def get_actor do
    GenServer.call(__MODULE__, :get_actor)
  end

  @impl true
  def init(_) do
    case :tenant_secrets.start() do
      {:ok, actor} -> {:ok, actor}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:get_actor, _from, actor) do
    {:reply, actor, actor}
  end
end
