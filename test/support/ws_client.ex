defmodule WsClient do
  @moduledoc """
  Simple WebSocket client for tests using WebSockex.
  Forwards all received text frames to the parent process.
  """

  use WebSockex

  def start_link(url, parent) do
    WebSockex.start_link(url, __MODULE__, %{parent: parent})
  end

  def send_text(pid, text) do
    WebSockex.send_frame(pid, {:text, text})
  end

  @impl true
  def handle_frame({:text, text}, state) do
    send(state.parent, {:ws_message, text})
    {:ok, state}
  end

  def handle_frame(_frame, state), do: {:ok, state}
end
