defmodule LeveeWeb.Plugs.WebSocket do
  @moduledoc """
  Plug that upgrades WebSocket connections at /socket/websocket
  to the beryl-backed SocketHandler.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(%{request_path: "/socket/websocket"} = conn, _opts) do
    channels = Levee.Channels.get_channels()

    conn
    |> WebSockAdapter.upgrade(
      LeveeWeb.SocketHandler,
      %{channels: channels},
      []
    )
    |> halt()
  end

  def call(conn, _opts), do: conn
end
