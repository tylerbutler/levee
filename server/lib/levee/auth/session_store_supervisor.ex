defmodule Levee.Auth.SessionStoreSupervisor do
  @moduledoc """
  Starts and registers the Gleam session store actor.

  Holds the actor Subject so Elixir callers can access it via `get_actor/0`.
  """
  use GenServer

  @compile {:no_warn_undefined, [:session_store]}

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Returns the Gleam actor Subject for the session store.
  """
  def get_actor do
    GenServer.call(__MODULE__, :get_actor)
  end

  @impl true
  def init(_) do
    case :session_store.start() do
      {:ok, actor} -> {:ok, actor}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:get_actor, _from, actor) do
    {:reply, actor, actor}
  end
end
