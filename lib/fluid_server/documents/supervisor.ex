defmodule FluidServer.Documents.Supervisor do
  @moduledoc """
  DynamicSupervisor for document sessions.

  Supervises document Session processes, allowing them to be started
  and stopped dynamically as documents are opened and closed.
  """

  use DynamicSupervisor

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
