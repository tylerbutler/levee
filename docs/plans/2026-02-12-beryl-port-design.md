# Port Levee DocumentChannel to Beryl

**Date:** 2026-02-12
**Status:** Approved
**Branch:** feat/channels

## Goal

Replace Phoenix.Channel with beryl for levee's real-time document collaboration WebSocket endpoint. Remove all Phoenix.Channel/Socket dependencies while keeping the Phoenix HTTP stack for REST APIs.

## Architecture

```
Client WebSocket --> Cowboy HTTP Server --> LeveeWeb.Socket (Elixir)
                                                 |
                                                 | Erlang messages
                                                 v
                                        beryl coordinator (Gleam OTP actor)
                                                 |
                                                 | pattern match
                                                 v
                                        DocumentChannel (Gleam)
                                                 |
                                                 | Elixir FFI
                                                 v
                                        Levee.Documents.Session (Elixir GenServer)
```

### Components

1. **`LeveeWeb.Socket`** (new, Elixir) — `:cowboy_websocket` behavior. Handles HTTP upgrade, frame parsing, connection lifecycle. Registers with beryl coordinator on connect, routes wire protocol messages to it, pushes outbound frames to client.

2. **`beryl/levee/document_channel.gleam`** (new, Gleam) — Beryl channel handler implementing the Fluid Framework protocol. Ports all logic from `DocumentChannel.ex`: JWT auth, session management, op submission, signal handling (v1/v2), noop, requestOps, delta catch-up.

3. **`beryl/levee/document_ffi.erl`** (new, Erlang) — FFI bridge for calling Elixir modules (`JWT`, `Session`, `Registry`, `TenantSecrets`) from Gleam.

### Message Routing

Session sends `{:op, msg}` and `{:signal, msg}` directly to `client_info.pid`. Today that PID is a Phoenix channel process; after the port it's the Cowboy handler process. The handler receives these via `websocket_info` and pushes them as WebSocket frames. Zero changes to Session.

```
Session --{:op, msg}--> Cowboy handler process --WebSocket frame--> Client
```

Process monitoring (`:DOWN`) works the same way — Session monitors the handler PID and cleans up on disconnect.

## Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| WebSocket transport | Cowboy handler (not wisp) | Levee uses Phoenix/Cowboy; beryl's wisp transport uses Mist |
| Message routing | Handler forwards directly | Zero Session changes; `send(pid, {:op, msg})` pattern unchanged |
| Channel logic location | Gleam (in beryl) | Type-safe, validates beryl as a real channel framework |
| Elixir interop | Erlang FFI module | Gleam calls JWT/Session/Registry via FFI bridge |

## Files

### Create

| File | Purpose | ~Lines |
|------|---------|--------|
| `lib/levee_web/socket.ex` | Cowboy WebSocket handler | ~80 |
| `beryl/src/beryl/levee/document_channel.gleam` | Fluid Framework channel handler | ~400 |
| `beryl/src/beryl/levee/document_ffi.erl` | FFI bridge to Elixir modules | ~60 |

### Modify

| File | Change |
|------|--------|
| `lib/levee_web/endpoint.ex` | Remove `socket "/socket"` macro; add Cowboy dispatch route |
| `lib/levee/application.ex` | Start beryl coordinator; register document channel |
| `test/levee_web/channels/document_channel_test.exs` | Rewrite with raw WebSocket client |

### Remove

| File | Reason |
|------|--------|
| `lib/levee_web/channels/user_socket.ex` | Replaced by `LeveeWeb.Socket` |
| `lib/levee_web/channels/document_channel.ex` | Logic moved to Gleam |

### Unchanged

- `lib/levee/documents/session.ex` — sends to PIDs (handler process instead of channel process)
- `lib/levee/auth/jwt.ex` — called from Gleam via FFI
- `lib/levee_web/router.ex` — REST routes unchanged
- All REST controllers and other modules

## Cowboy Handler Design

`LeveeWeb.Socket` implements `:cowboy_websocket`:

- `init/2` — Accept upgrade, pass coordinator subject in state
- `websocket_init/1` — Generate socket ID, register with coordinator via `SocketConnected`
- `websocket_handle({:text, text}, state)` — Decode wire protocol, route to coordinator (`Join`, `HandleIn`, `Heartbeat`, `Leave`)
- `websocket_info({:send, text}, state)` — Push text frame to client (called by coordinator's send function)
- `websocket_info({:op, msg}, state)` — Encode op message as wire protocol, push to client
- `websocket_info({:signal, msg}, state)` — Encode signal message, push to client
- `websocket_info({:DOWN, ...}, state)` — Session died, close connection
- `terminate/3` — Notify coordinator via `SocketDisconnected`

The coordinator's `send` function captures `self()` (the handler process PID) to push messages back.

## Document Channel Design

`beryl/levee/document_channel.gleam` uses beryl's `Channel` type:

**Assigns type:**
```gleam
type DocumentAssigns {
  // Pre-connect state
  Pending(tenant_id: String, document_id: String)
  // Post-connect state
  Connected(
    tenant_id: String,
    document_id: String,
    client_id: String,
    mode: String,
    session_pid: Dynamic,
    claims: Dynamic,
  )
}
```

**Events handled:**
- `connect_document` — Validate fields, verify JWT, create/get session, client_join
- `submitOp` — Check connected, check client ID, check write scope, delegate to Session
- `submitSignal` — Check connected, check client ID, normalize v1/v2, delegate to Session
- `noop` — Update client RSN
- `requestOps` — Delta catch-up from Session

**FFI calls needed:**
- `jwt_verify(token, tenant_id)` → `{:ok, claims}` | `{:error, reason}`
- `jwt_expired(claims)` → `Bool`
- `jwt_has_read_scope(claims)` / `jwt_has_write_scope(claims)` → `Bool`
- `registry_get_or_create_session(tenant_id, doc_id)` → `{:ok, pid}` | `{:error, reason}`
- `session_client_join(pid, connect_msg)` → `{:ok, {client_id, response}}` | `{:error, reason}`
- `session_submit_ops(pid, client_id, batches)` → `:ok` | `{:error, nacks}`
- `session_submit_signals(pid, client_id, signals)` → `:ok`
- `session_update_client_rsn(pid, client_id, rsn)` → `:ok`
- `session_get_ops_since(pid, sn)` → `{:ok, ops}` | `{:error, reason}`

## Test Strategy

Rewrite `DocumentChannelTest` using raw WebSocket connections via `:gun` (Erlang HTTP/WebSocket client, already available via Cowboy).

Tests connect to the actual Cowboy endpoint, send/receive Phoenix wire protocol messages `[join_ref, ref, topic, event, payload]`, and assert on responses. This tests the full stack: Cowboy handler -> beryl coordinator -> document channel -> Session.

Beryl's existing unit tests (46 passing) cover wire protocol, topic matching, socket state, and coordinator logic independently.
