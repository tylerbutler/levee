defmodule Levee.Channels do
  @moduledoc """
  Manages the beryl channels coordinator lifecycle.

  Starts the beryl channels system and registers the document channel handler
  at application startup. Provides access to the Channels struct for WebSocket
  upgrade.
  """

  use GenServer
  # Gleam modules are loaded at runtime from BEAM files
  @compile {:no_warn_undefined, [:beryl@levee@runtime]}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Get the beryl Channels struct for passing to WebSocket handlers."
  def get_channels do
    GenServer.call(__MODULE__, :get_channels)
  end

  @impl true
  def init(_opts) do
    case :beryl@levee@runtime.start() do
      {:ok, channels} ->
        {:ok, %{channels: channels}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:get_channels, _from, state) do
    {:reply, state.channels, state}
  end
end
