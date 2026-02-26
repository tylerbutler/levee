defmodule Levee.OAuth.StateStoreSupervisor do
  @moduledoc """
  Starts and registers the Gleam OAuth state store actor.
  """
  use GenServer

  @compile {:no_warn_undefined, [:levee_oauth@state_store]}

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def get_actor do
    GenServer.call(__MODULE__, :get_actor)
  end

  @impl true
  def init(_) do
    case :levee_oauth@state_store.start() do
      {:ok, actor} -> {:ok, actor}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:get_actor, _from, actor) do
    {:reply, actor, actor}
  end
end
