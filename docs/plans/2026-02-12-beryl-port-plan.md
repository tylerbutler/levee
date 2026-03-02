# Beryl Port Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace Phoenix.Channel with beryl for levee's real-time WebSocket endpoint.

**Architecture:** WebSocket handler using `WebSock` behavior (Bandit/Phoenix 1.8), plugged into the endpoint before the router. Handler registers with beryl's coordinator OTP actor. Document channel logic ported to Gleam. Session GenServer unchanged — sends to handler PID.

**Tech Stack:** Elixir (WebSock/Plug), Gleam (beryl channels), Erlang FFI, Bandit HTTP server

**Design doc:** `docs/plans/2026-02-12-beryl-port-design.md`

---

### Task 1: Add beryl to Gleam build pipeline and add test dependency

**Files:**
- Modify: `mix.exs` — add beryl to gleam_build, add websockex test dep
- Modify: `lib/levee/application.ex` — add beryl to load_gleam_modules

**Step 1: Add websockex test dependency to mix.exs**

In `mix.exs`, add to the `deps` list:
```elixir
{:websockex, "~> 0.4", only: :test}
```

**Step 2: Add beryl to the gleam_build alias**

In `mix.exs`, update the `gleam_build` function:
```elixir
gleam_projects = ["levee_protocol", "levee_auth", "beryl"]
```

**Step 3: Add beryl to load_gleam_modules in application.ex**

In `lib/levee/application.ex`, update `load_gleam_modules/0`:

Add to `base_paths`:
```elixir
Path.join([app_root, "beryl", "build", "dev", "erlang"]),
"/app/beryl/build/dev/erlang"
```

Add to `gleam_modules`:
```elixir
"beryl"
```

**Step 4: Install deps and verify build**

Run: `mix deps.get && mix compile`
Expected: Compiles successfully, beryl BEAM modules loaded

**Step 5: Verify beryl modules are accessible from Elixir**

Run: `mix run -e "IO.inspect(:beryl@coordinator.start())"`
Expected: Prints `{:ok, <PID>}` — beryl coordinator starts successfully

**Step 6: Commit**

```
feat(beryl): add beryl to build pipeline and load path
```

---

### Task 2: Create Erlang FFI bridge for Elixir interop

**Files:**
- Create: `beryl/src/beryl/levee/document_ffi.erl`

This module wraps Elixir function calls so Gleam can call them via `@external`. Elixir modules compile to Erlang, so we call them directly with their Erlang module names (e.g., `'Elixir.Levee.Auth.JWT'`).

**Step 1: Create the FFI module**

Create `beryl/src/beryl/levee/document_ffi.erl`:

```erlang
-module(beryl@levee@document_ffi).
-export([
    jwt_verify/2,
    jwt_expired/1,
    jwt_has_read_scope/1,
    jwt_has_write_scope/1,
    registry_get_or_create_session/2,
    session_client_join/2,
    session_submit_ops/3,
    session_submit_signals/3,
    session_update_client_rsn/3,
    session_get_ops_since/2,
    session_client_leave/2,
    process_monitor/1
]).

%% JWT functions
jwt_verify(Token, TenantId) ->
    'Elixir.Levee.Auth.JWT':verify(Token, TenantId).

jwt_expired(Claims) ->
    'Elixir.Levee.Auth.JWT':'expired?'(Claims).

jwt_has_read_scope(Claims) ->
    'Elixir.Levee.Auth.JWT':'has_read_scope?'(Claims).

jwt_has_write_scope(Claims) ->
    'Elixir.Levee.Auth.JWT':'has_write_scope?'(Claims).

%% Registry functions
registry_get_or_create_session(TenantId, DocumentId) ->
    'Elixir.Levee.Documents.Registry':get_or_create_session(TenantId, DocumentId).

%% Session functions - these use GenServer.call, so caller PID matters
session_client_join(SessionPid, ConnectMsg) ->
    'Elixir.Levee.Documents.Session':client_join(SessionPid, ConnectMsg).

session_submit_ops(SessionPid, ClientId, Batches) ->
    'Elixir.Levee.Documents.Session':submit_ops(SessionPid, ClientId, Batches).

session_submit_signals(SessionPid, ClientId, Signals) ->
    'Elixir.Levee.Documents.Session':submit_signals(SessionPid, ClientId, Signals).

session_update_client_rsn(SessionPid, ClientId, Rsn) ->
    'Elixir.Levee.Documents.Session':update_client_rsn(SessionPid, ClientId, Rsn).

session_get_ops_since(SessionPid, Sn) ->
    'Elixir.Levee.Documents.Session':get_ops_since(SessionPid, Sn).

session_client_leave(SessionPid, ClientId) ->
    'Elixir.Levee.Documents.Session':client_leave(SessionPid, ClientId).

%% Process monitoring
process_monitor(Pid) ->
    erlang:monitor(process, Pid).
```

**Step 2: Build beryl and verify FFI compiles**

Run: `cd beryl && gleam build`
Expected: Compiles without errors

**Step 3: Commit**

```
feat(beryl): add Erlang FFI bridge for Elixir interop
```

---

### Task 3: Create DocumentChannel in Gleam

**Files:**
- Create: `beryl/src/beryl/levee/document_channel.gleam`

This is the main business logic port. The Gleam channel handler implements the Fluid Framework protocol using beryl's `Channel` type. It calls Elixir modules via the FFI bridge.

**Important:** The current Phoenix DocumentChannel uses `handle_info` to receive `{:op, msg}` and `{:signal, msg}` from Session. In the beryl architecture, these messages go directly to the WebSocket handler process (not through the coordinator), so they're handled in the Elixir WebSocket handler, not in this Gleam channel. This channel only handles `handle_in` events from the client.

**Step 1: Create the document channel module**

Create `beryl/src/beryl/levee/document_channel.gleam` with:

1. `DocumentAssigns` type (Pending / Connected variants)
2. `new()` function returning a `Channel(DocumentAssigns, Nil)`
3. `join` handler — parse topic into tenant_id:document_id, return Pending assigns
4. `handle_in` handler dispatching on event name:
   - `"connect_document"` — validate fields, JWT verify, get/create session, client_join
   - `"submitOp"` — check connected, check client_id, check write scope, delegate to Session
   - `"submitSignal"` — check connected, check client_id, delegate to Session
   - `"noop"` — update client RSN
   - `"requestOps"` — get ops since SN, push to client
5. `terminate` handler — call session_client_leave

All Elixir calls go through `@external(erlang, "beryl@levee@document_ffi", ...)` FFI.

Since `Dynamic` is used for Elixir interop types (claims, session_pid, connect_msg payloads), use `gleam/dynamic` for these.

**Step 2: Build and verify**

Run: `cd beryl && gleam build`
Expected: Compiles without errors

**Step 3: Commit**

```
feat(beryl): add DocumentChannel in Gleam with Fluid Framework protocol
```

---

### Task 4: Create WebSocket handler (Elixir WebSock)

**Files:**
- Create: `lib/levee_web/socket_handler.ex`

This module implements the `WebSock` behavior. It:
- Generates a socket ID on init
- Registers with beryl coordinator
- Parses wire protocol frames and routes to coordinator
- Receives `{:op, msg}` and `{:signal, msg}` from Session and pushes to client
- Handles Session process `:DOWN` messages
- Notifies coordinator on disconnect

**Step 1: Create the WebSocket handler**

Create `lib/levee_web/socket_handler.ex`:

```elixir
defmodule LeveeWeb.SocketHandler do
  @behaviour WebSock

  require Logger

  @impl WebSock
  def init(state) do
    socket_id = generate_socket_id()
    coordinator = state.coordinator

    # Create send function that sends back to this process
    me = self()
    send_fn = fn text ->
      send(me, {:send, text})
      {:ok, nil}
    end

    # Register with beryl coordinator
    :beryl@coordinator.SocketConnected(socket_id, send_fn)
    |> then(&send(coordinator, &1))

    {:ok, Map.merge(state, %{socket_id: socket_id, coordinator: coordinator})}
  end

  @impl WebSock
  def handle_in({text, [opcode: :text]}, state) do
    case :beryl@wire.decode_message(text) do
      {:ok, msg} ->
        route_message(state, msg)
        {:ok, state}

      {:error, _} ->
        Logger.debug("Invalid wire message received")
        {:ok, state}
    end
  end

  def handle_in(_other, state), do: {:ok, state}

  @impl WebSock
  def handle_info({:send, text}, state) do
    {:push, {:text, text}, state}
  end

  def handle_info({:op, op_message}, state) do
    # Session sends op messages directly to this process
    # Encode as wire protocol push and send to client
    ops = op_message["op"] || []
    {summary_events, regular_ops} =
      Enum.split_with(ops, fn op -> op["type"] in ["summaryAck", "summaryNack"] end)

    frames =
      Enum.map(summary_events, fn event ->
        {:text, encode_push(op_message["documentId"] || "", event["type"], event)}
      end) ++
      if regular_ops != [] do
        [{:text, encode_push(
          op_message["documentId"] || "",
          "op",
          %{op_message | "op" => regular_ops}
        )}]
      else
        []
      end

    case frames do
      [] -> {:ok, state}
      _ -> {:push, frames, state}
    end
  end

  def handle_info({:signal, signal_message}, state) do
    frame = {:text, encode_push("", "signal", signal_message)}
    {:push, frame, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    if state[:session_pid] == pid do
      Logger.warning("Session process died, closing WebSocket")
      {:stop, :normal, state}
    else
      {:ok, state}
    end
  end

  def handle_info(_msg, state), do: {:ok, state}

  @impl WebSock
  def terminate(_reason, state) do
    if state[:coordinator] && state[:socket_id] do
      send(state.coordinator, :beryl@coordinator.SocketDisconnected(state.socket_id))
    end
    :ok
  end

  # Route parsed wire message to coordinator
  defp route_message(state, msg) do
    coord = state.coordinator
    sid = state.socket_id

    case msg.event do
      "phx_join" ->
        ref = msg.ref |> unwrap_option("")
        send(coord, :beryl@coordinator.Join(sid, msg.topic, msg.payload, msg.join_ref, ref))

      "phx_leave" ->
        send(coord, :beryl@coordinator.Leave(sid, msg.topic, msg.ref))

      "heartbeat" ->
        ref = msg.ref |> unwrap_option("")
        send(coord, :beryl@coordinator.Heartbeat(sid, ref))

      event ->
        send(coord, :beryl@coordinator.HandleIn(sid, msg.topic, event, msg.payload, msg.ref))
    end
  end

  defp unwrap_option({:some, val}, _default), do: val
  defp unwrap_option(:none, default), do: default
  defp unwrap_option(nil, default), do: default

  defp generate_socket_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  # Encode a server push as wire protocol: [null, null, topic, event, payload]
  defp encode_push(topic, event, payload) do
    Jason.encode!([nil, nil, topic, event, payload])
  end
end
```

**Step 2: Verify it compiles**

Run: `mix compile`
Expected: Compiles successfully

**Step 3: Commit**

```
feat(web): add WebSock handler for beryl WebSocket transport
```

---

### Task 5: Create WebSocket Plug and wire up endpoint

**Files:**
- Create: `lib/levee_web/plugs/websocket.ex`
- Modify: `lib/levee_web/endpoint.ex` — add WebSocket plug, remove Phoenix socket
- Modify: `lib/levee/application.ex` — start beryl coordinator, register channel

**Step 1: Create the WebSocket upgrade Plug**

Create `lib/levee_web/plugs/websocket.ex`:

```elixir
defmodule LeveeWeb.Plugs.WebSocket do
  @moduledoc """
  Plug that upgrades WebSocket connections at /socket/websocket
  to the beryl-backed SocketHandler.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(%{request_path: "/socket/websocket"} = conn, _opts) do
    coordinator = Levee.Channels.coordinator()

    conn
    |> WebSockAdapter.upgrade(
      LeveeWeb.SocketHandler,
      %{coordinator: coordinator},
      []
    )
    |> halt()
  end

  def call(conn, _opts), do: conn
end
```

**Step 2: Create the Levee.Channels module for coordinator lifecycle**

Create `lib/levee/channels.ex`:

```elixir
defmodule Levee.Channels do
  @moduledoc """
  Manages the beryl channels coordinator lifecycle.
  """

  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def coordinator do
    GenServer.call(__MODULE__, :get_coordinator)
  end

  @impl true
  def init(_opts) do
    # Start beryl coordinator
    case :beryl@coordinator.start() do
      {:ok, coord} ->
        # Register document channel
        channel = :beryl@levee@document_channel.new()
        :beryl.register(coord, "document:*", channel)
        {:ok, %{coordinator: coord}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:get_coordinator, _from, state) do
    {:reply, state.coordinator, state}
  end
end
```

**Step 3: Update endpoint.ex**

In `lib/levee_web/endpoint.ex`:
- Remove the `socket "/socket", LeveeWeb.UserSocket, websocket: true, longpoll: false` line
- Add the WebSocket plug before the router:

```elixir
# Beryl WebSocket endpoint (replaces Phoenix.Channel)
plug LeveeWeb.Plugs.WebSocket
```

Place it after `Plug.Session` and before `LeveeWeb.Router`.

**Step 4: Update application.ex**

In `lib/levee/application.ex`, add `Levee.Channels` to the children list, before `LeveeWeb.Endpoint`:

```elixir
# Beryl channels coordinator
Levee.Channels,
```

**Step 5: Verify the app starts**

Run: `mix phx.server`
Expected: Server starts on port 4000, no errors about missing socket

**Step 6: Commit**

```
feat: wire beryl channels into Phoenix endpoint and application
```

---

### Task 6: Remove old Phoenix channel files

**Files:**
- Remove: `lib/levee_web/channels/user_socket.ex`
- Remove: `lib/levee_web/channels/document_channel.ex`

**Step 1: Remove old files**

```bash
git rm lib/levee_web/channels/user_socket.ex
git rm lib/levee_web/channels/document_channel.ex
```

**Step 2: Verify compilation**

Run: `mix compile`
Expected: Compiles with no errors. If there are references to the removed modules, fix them.

Check for any remaining references:
```bash
rg "UserSocket|DocumentChannel" lib/ --type elixir
```

Expected: No matches in `lib/` (test files may still reference them — that's OK, we fix those next).

**Step 3: Commit**

```
refactor: remove Phoenix.Channel files replaced by beryl
```

---

### Task 7: Rewrite channel tests for WebSocket handler

**Files:**
- Modify: `test/levee_web/channels/document_channel_test.exs` — full rewrite
- Modify: `test/support/channel_case.ex` — update or replace

The existing tests use `Phoenix.ChannelTest` helpers. We rewrite them using `websockex` to make raw WebSocket connections and send/receive wire protocol messages.

**Step 1: Create a WebSocket test helper**

Update `test/support/channel_case.ex` to provide WebSocket test utilities:

```elixir
defmodule LeveeWeb.WebSocketCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      import LeveeWeb.WebSocketCase
    end
  end

  setup _tags do
    {:ok, _} = Application.ensure_all_started(:levee)
    :ok
  end

  @doc "Connect to the WebSocket endpoint"
  def ws_connect do
    url = "ws://localhost:#{port()}/socket/websocket"
    {:ok, pid} = WsClient.start_link(url, self())
    pid
  end

  @doc "Send a wire protocol message"
  def ws_push(ws, join_ref, ref, topic, event, payload) do
    msg = Jason.encode!([join_ref, ref, topic, event, payload])
    WsClient.send_text(ws, msg)
  end

  @doc "Assert a wire protocol message is received"
  def assert_ws_push(event, timeout \\ 1000) do
    receive do
      {:ws_message, text} ->
        [join_ref, ref, topic, recv_event, payload] = Jason.decode!(text)
        assert recv_event == event
        %{join_ref: join_ref, ref: ref, topic: topic, event: recv_event, payload: payload}
    after
      timeout -> flunk("Expected to receive #{event} within #{timeout}ms")
    end
  end

  @doc "Assert a wire protocol reply is received"
  def assert_ws_reply(ref_val, status, timeout \\ 1000) do
    receive do
      {:ws_message, text} ->
        [_jr, recv_ref, _topic, "phx_reply", %{"status" => recv_status} = payload] =
          Jason.decode!(text)
        assert recv_ref == ref_val
        assert recv_status == status
        payload["response"]
    after
      timeout -> flunk("Expected reply for ref #{ref_val} within #{timeout}ms")
    end
  end

  defp port do
    Application.get_env(:levee, LeveeWeb.Endpoint)[:http][:port] || 4002
  end
end
```

**Step 2: Create a simple WebSocket client GenServer**

Create `test/support/ws_client.ex`:

```elixir
defmodule WsClient do
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
```

**Step 3: Rewrite document_channel_test.exs**

Rewrite `test/levee_web/channels/document_channel_test.exs` using the new helpers. Port each existing test:
- `connect_document` success/error cases
- `submitOp` success/nack cases
- `submitSignal` v1/v2 format cases
- `noop` RSN update
- `requestOps` delta catch-up
- Read-only mode restriction

Each test: connect WebSocket, join topic, send wire protocol messages, assert replies.

**Step 4: Run tests**

Run: `mix test test/levee_web/channels/`
Expected: All tests pass

**Step 5: Commit**

```
test: rewrite channel tests for beryl WebSocket handler
```

---

### Task 8: Final verification

**Step 1: Run all tests**

Run: `mix test`
Expected: All tests pass (both new WebSocket tests and existing REST/auth tests)

**Step 2: Run beryl tests**

Run: `cd beryl && gleam test`
Expected: All 46 tests pass

**Step 3: Format check**

Run: `mix format --check-formatted && cd beryl && gleam format --check`
Expected: All formatted

**Step 4: Manual smoke test**

Run: `mix phx.server`
- Verify server starts on port 4000
- Verify `/health` endpoint works
- Verify WebSocket connects at `/socket/websocket`

**Step 5: Commit any final fixes, then verify clean state**

Run: `mix test && cd beryl && gleam test`
Expected: All green

---

## Key Risk: Gleam ↔ Elixir type mapping in FFI

The DocumentChannel in Gleam receives `Dynamic` payloads from the wire protocol. It passes these to Elixir functions (Session, JWT) which expect Elixir maps/strings. Since Gleam's `Dynamic` is just the Erlang term underneath, this should work transparently. But watch for:

- Gleam `Option` is `{some, value}` / `none` — Elixir expects `nil` or value
- Gleam `Result` is `{ok, value}` / `{error, reason}` — matches Elixir tuples
- Gleam strings are Erlang binaries — matches Elixir strings
- Gleam `Dict` is NOT an Elixir map — use `gleam@dict` functions or convert

The FFI bridge handles these conversions explicitly where needed.

## Task Dependency Graph

```
Task 1 (build pipeline)
  └─► Task 2 (FFI bridge)
       └─► Task 3 (document channel)
            └─► Task 4 (WebSocket handler)
                 └─► Task 5 (wiring)
                      └─► Task 6 (remove old files)
                           └─► Task 7 (tests)
                                └─► Task 8 (verification)
```

All tasks are sequential — each depends on the previous.
