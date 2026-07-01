defmodule LeveeWeb.SocketIOPlug do
  @moduledoc """
  Minimal Socket.IO websocket endpoint used by the official Routerlicious driver.

  Phoenix Channels remain available at `/socket`; this plug handles the
  Socket.IO/Engine.IO websocket upgrade path used by `socket.io-client`.
  """

  import Plug.Conn

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: "GET", path_info: ["socket.io" | _]} = conn, _opts) do
    conn
    |> WebSockAdapter.upgrade(LeveeWeb.SocketIOWebSock, %{}, timeout: 60_000)
    |> halt()
  end

  def call(conn, _opts), do: conn
end
