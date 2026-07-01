defmodule LeveeWeb.SocketIOPlug do
  @moduledoc """
  Minimal Socket.IO websocket endpoint used by the official Routerlicious driver.

  Phoenix Channels remain available at `/socket`; this plug handles the
  Socket.IO/Engine.IO websocket upgrade path used by `socket.io-client`.

  ## Temporary migration scaffolding — removal gate

  This plug (and `LeveeWeb.SocketIOWebSock`) exist only until the standalone
  `sluice/` Gleam service can terminate this connection directly. Per
  `docs/adr/003-sluice-cutover-readiness.md`, it may only be removed once:

    * `client/packages/levee-driver/test/integration/sluice-routerlicious.test.ts`
      has zero outstanding `it.todo` conformance gaps for both the
      `sluice-direct` and `levee-proxy` targets (tracked in
      `client/packages/levee-driver/test/integration/cutover-readiness.json`,
      `expectedOutstandingTodoCount`), and
    * `readyForCutover` in that same manifest has been deliberately flipped
      to `true`.

  Run `just check-cutover-readiness` to check current status.
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
