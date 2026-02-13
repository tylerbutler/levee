# Beryl - Implementation Plan

**Building on Wisp PR #144 WebSocket support**

A type-safe library for real-time WebSocket communication in Gleam, with channels, presence, and pub/sub.

---

## Core Concepts

| Concept      | Description                                           |
|--------------|-------------------------------------------------------|
| **Channel**  | Handler module for a topic pattern (e.g., `"room:*"`) |
| **Topic**    | String identifier like `"room:lobby"`, `"user:123"`   |
| **Socket**   | A connected client with typed assigns (state)         |
| **Presence** | Track who's in a topic with metadata                  |
| **PubSub**   | Internal broadcast mechanism                          |

---

## Module Structure

```
beryl/src/
├── beryl.gleam           # Main public API
├── beryl/
│   ├── socket.gleam               # Socket type and operations
│   ├── channel.gleam              # Channel behavior/interface
│   ├── topic.gleam                # Topic parsing and matching
│   ├── presence.gleam             # Presence tracking
│   ├── pubsub.gleam               # Internal pub/sub actor
│   ├── registry.gleam             # Socket registry actor
│   ├── supervisor.gleam           # Socket supervision
│   └── transport/
│       └── websocket.gleam        # Wisp WS integration
```

---

## Key Types

### Socket (Type-Safe Assigns)

```gleam
// beryl/socket.gleam

import gleam/set.{type Set}

/// A connected client socket with typed assigns
///
/// The `assigns` type parameter allows compile-time checking of socket state.
/// Each channel defines its own assigns type.
pub opaque type Socket(assigns) {
  Socket(
    id: String,
    assigns: assigns,
    topics: Set(String),
    transport: Transport,
    channels_subject: Subject(ChannelsMessage),
  )
}

/// Create initial socket with assigns
pub fn new(id: String, assigns: assigns, transport: Transport) -> Socket(assigns)

/// Update assigns (returns new socket)
pub fn set_assigns(socket: Socket(a), assigns: a) -> Socket(a)

/// Get current assigns
pub fn get_assigns(socket: Socket(a)) -> a

/// Map assigns to new type (for channel transitions)
pub fn map_assigns(socket: Socket(a), f: fn(a) -> b) -> Socket(b)

/// Get socket id
pub fn id(socket: Socket(a)) -> String

/// Get subscribed topics
pub fn topics(socket: Socket(a)) -> Set(String)
```

### Channel Behavior

```gleam
// beryl/channel.gleam

import gleam/json.{type Json}
import gleam/option.{type Option}

/// Result of joining a channel
pub type JoinResult(assigns) {
  JoinOk(reply: Option(Json), socket: Socket(assigns))
  JoinError(reason: Json)
}

/// Result of handling a message
pub type HandleResult(assigns) {
  NoReply(socket: Socket(assigns))
  Reply(event: String, payload: Json, socket: Socket(assigns))
  Push(event: String, payload: Json, socket: Socket(assigns))
  Stop(reason: StopReason)
}

/// Why a channel is stopping
pub type StopReason {
  Normal
  Shutdown
  Error(String)
}

/// Channel behavior - implement this for each channel type
///
/// Type parameters:
/// - `assigns`: Socket state type for this channel
/// - `info`: Type of messages from other processes (via handle_info)
pub type Channel(assigns, info) {
  Channel(
    /// Called when client attempts to join a topic
    join: fn(topic: String, payload: Json, socket: Socket(assigns)) ->
      JoinResult(assigns),

    /// Called when client sends a message to this channel
    handle_in: fn(event: String, payload: Json, socket: Socket(assigns)) ->
      HandleResult(assigns),

    /// Called when this socket receives a message from another process
    /// Use this for server-initiated pushes, cleanup notifications, etc.
    handle_info: fn(info, socket: Socket(assigns)) ->
      HandleResult(assigns),

    /// Called when client leaves or disconnects
    terminate: fn(StopReason, socket: Socket(assigns)) -> Nil,
  )
}

/// Create a channel with default handlers
pub fn new(
  join: fn(String, Json, Socket(assigns)) -> JoinResult(assigns),
) -> Channel(assigns, info) {
  Channel(
    join: join,
    handle_in: fn(_, _, socket) { NoReply(socket) },
    handle_info: fn(_, socket) { NoReply(socket) },
    terminate: fn(_, _) { Nil },
  )
}

/// Builder pattern for channel construction
pub fn with_handle_in(
  channel: Channel(assigns, info),
  handler: fn(String, Json, Socket(assigns)) -> HandleResult(assigns),
) -> Channel(assigns, info)

pub fn with_handle_info(
  channel: Channel(assigns, info),
  handler: fn(info, Socket(assigns)) -> HandleResult(assigns),
) -> Channel(assigns, info)

pub fn with_terminate(
  channel: Channel(assigns, info),
  handler: fn(StopReason, Socket(assigns)) -> Nil,
) -> Channel(assigns, info)
```

### Topic Pattern Matching

```gleam
// beryl/topic.gleam

/// Topic pattern for routing
pub type TopicPattern {
  /// Exact match: "room:lobby"
  Exact(String)
  /// Wildcard suffix: "room:*" matches "room:lobby", "room:123"
  Wildcard(prefix: String)
}

/// Parse a pattern string into TopicPattern
/// "room:*" -> Wildcard("room:")
/// "room:lobby" -> Exact("room:lobby")
pub fn parse_pattern(pattern: String) -> TopicPattern

/// Parse topic into segments
/// "room:lobby:messages" -> ["room", "lobby", "messages"]
pub fn segments(topic: String) -> List(String)

/// Check if topic matches pattern
pub fn matches(pattern: TopicPattern, topic: String) -> Bool

/// Extract wildcard portion
/// Wildcard("room:") + "room:lobby" -> Ok("lobby")
/// Exact(_) + _ -> Error(Nil)
pub fn extract_id(pattern: TopicPattern, topic: String) -> Result(String, Nil)
```

---

## Main API

```gleam
// beryl.gleam

import gleam/erlang/process.{type Subject}
import gleam/json.{type Json}
import beryl/channel.{type Channel}
import beryl/socket.{type Socket}
import beryl/presence.{type PresenceList}

/// Configuration for the channels system
pub type Config {
  Config(
    /// Heartbeat interval in milliseconds (default: 30000)
    heartbeat_interval_ms: Int,
    /// Heartbeat timeout - disconnect if no response (default: 60000)
    heartbeat_timeout_ms: Int,
    /// Max connections per IP (0 = unlimited)
    max_connections_per_ip: Int,
  )
}

/// Default configuration
pub fn default_config() -> Config

/// Channels system handle
pub opaque type Channels

/// Start the channels system
/// Call once at application startup
pub fn start(config: Config) -> Result(Channels, StartError)

/// Start errors
pub type StartError {
  PubSubStartFailed
  RegistryStartFailed
  SupervisorStartFailed
}

/// Register a channel handler for a topic pattern
///
/// Example:
/// ```gleam
/// channels.register(ch, "room:*", room_channel.new())
/// channels.register(ch, "user:*", user_channel.new())
/// ```
pub fn register(
  channels: Channels,
  pattern: String,
  handler: Channel(assigns, info),
) -> Result(Nil, RegisterError)

pub type RegisterError {
  PatternAlreadyRegistered(String)
  InvalidPattern(String)
}

/// Broadcast to all subscribers of a topic
pub fn broadcast(
  channels: Channels,
  topic: String,
  event: String,
  payload: Json,
) -> Nil

/// Broadcast to all subscribers except one socket
pub fn broadcast_from(
  channels: Channels,
  except: Socket(a),
  topic: String,
  event: String,
  payload: Json,
) -> Nil

/// Push a message to a specific socket
pub fn push(socket: Socket(a), event: String, payload: Json) -> Nil

/// Get topic id from a topic string using the registered pattern
/// "room:lobby" with pattern "room:*" -> Ok("lobby")
pub fn topic_id(channels: Channels, topic: String) -> Result(String, Nil)

// Re-exports for convenience
pub const socket = beryl/socket
pub const channel = beryl/channel
pub const presence = beryl/presence
```

---

## Wisp Integration

```gleam
// beryl/transport/websocket.gleam

import beryl.{type Channels}
import wisp.{type Request, type Response}

/// Configuration for WebSocket transport
pub type TransportConfig {
  TransportConfig(
    /// URL path to upgrade (e.g., "/socket")
    path: String,
    /// Optional authentication function
    /// Called before socket creation, can reject connection
    authenticate: Option(fn(Request) -> Result(AuthResult, AuthError)),
  )
}

/// Result of authentication
pub type AuthResult {
  AuthResult(
    /// User identifier
    user_id: String,
    /// Optional metadata to include in socket
    metadata: Dict(String, Json),
  )
}

pub type AuthError {
  Unauthorized(String)
  Forbidden(String)
}

/// Default transport config
pub fn default_transport_config(path: String) -> TransportConfig

/// Upgrade WebSocket connections to channels
///
/// Usage:
/// ```gleam
/// fn handle_request(req: Request, ctx: Context) -> Response {
///   // Try WebSocket upgrade first
///   use <- websocket.upgrade(req, ctx.channels, transport_config())
///
///   // Fall through to HTTP routing if not a WebSocket request
///   case wisp.path_segments(req) {
///     [] -> home_page(req)
///     ["api", ..rest] -> api_routes(req, rest, ctx)
///     _ -> wisp.not_found()
///   }
/// }
/// ```
pub fn upgrade(
  request: Request,
  channels: Channels,
  config: TransportConfig,
  next: fn() -> Response,
) -> Response

/// Wire format for messages (Phoenix-compatible)
/// [join_ref, ref, topic, event, payload]
///
/// This enables compatibility with phoenix.js client library
pub type WireMessage {
  WireMessage(
    join_ref: Option(String),
    ref: Option(String),
    topic: String,
    event: String,
    payload: Json,
  )
}

/// Parse incoming WebSocket frame to WireMessage
pub fn parse_message(frame: String) -> Result(WireMessage, ParseError)

/// Encode WireMessage to WebSocket frame
pub fn encode_message(message: WireMessage) -> String
```

---

## Presence API

```gleam
// beryl/presence.gleam

import gleam/dict.{type Dict}
import gleam/json.{type Json}
import beryl/socket.{type Socket}

/// Presence metadata for a single presence entry
pub type PresenceMeta {
  PresenceMeta(
    /// Unique reference for this presence (for multi-device)
    phx_ref: String,
    /// User-defined metadata
    meta: Json,
    /// When this presence was tracked
    online_at: Int,
  )
}

/// List of presences keyed by user identifier
pub type PresenceList =
  Dict(String, List(PresenceMeta))

/// Diff between two presence states
pub type PresenceDiff {
  PresenceDiff(
    joins: PresenceList,
    leaves: PresenceList,
  )
}

/// Track a socket's presence in a topic
///
/// The key is typically a user ID. Multiple presences per key
/// are supported (e.g., user connected from multiple devices).
pub fn track(
  socket: Socket(a),
  topic: String,
  key: String,
  meta: Json,
) -> Result(Nil, PresenceError)

/// Update presence metadata for an existing presence
pub fn update(
  socket: Socket(a),
  topic: String,
  key: String,
  meta: Json,
) -> Result(Nil, PresenceError)

/// Stop tracking a specific presence
pub fn untrack(socket: Socket(a), topic: String, key: String) -> Nil

/// Untrack all presences for a socket (called on disconnect)
pub fn untrack_all(socket: Socket(a)) -> Nil

/// List all presences for a topic
pub fn list(channels: Channels, topic: String) -> PresenceList

/// Get presence diff between two states
pub fn diff(old: PresenceList, new: PresenceList) -> PresenceDiff

pub type PresenceError {
  NotTracked
  PresenceSystemUnavailable
}
```

---

## Internal Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         Channels                                 │
│                                                                  │
│  ┌─────────────┐  ┌─────────────┐  ┌────────────────────────┐   │
│  │   PubSub    │  │  Registry   │  │       Presence         │   │
│  │   Actor     │  │   Actor     │  │        Actor           │   │
│  │             │  │             │  │                        │   │
│  │ - topics    │  │ - socket    │  │ - track/untrack        │   │
│  │ - subscrib- │  │   lookup    │  │ - sync state           │   │
│  │   tions     │  │ - cleanup   │  │ - broadcast diff       │   │
│  └──────┬──────┘  └──────┬──────┘  └───────────┬────────────┘   │
│         │                │                      │                │
│         └────────────────┼──────────────────────┘                │
│                          │                                       │
│  ┌───────────────────────┴────────────────────────────────────┐  │
│  │                    Channel Router                           │  │
│  │                                                             │  │
│  │   Pattern         Handler                                   │  │
│  │   ─────────────────────────────                            │  │
│  │   "room:*"    ->  RoomChannel                              │  │
│  │   "user:*"    ->  UserChannel                              │  │
│  │   "doc:*:*"   ->  DocumentChannel                          │  │
│  └───────────────────────┬────────────────────────────────────┘  │
│                          │                                       │
│  ┌───────────────────────┴────────────────────────────────────┐  │
│  │              Socket Supervisor (DynamicSupervisor)          │  │
│  └───────────────────────┬────────────────────────────────────┘  │
│                          │                                       │
└──────────────────────────┼───────────────────────────────────────┘
                           │
        ┌──────────────────┼──────────────────┐
        │                  │                  │
   ┌────┴────┐       ┌────┴────┐       ┌────┴────┐
   │ Socket  │       │ Socket  │       │ Socket  │
   │  Actor  │       │  Actor  │       │  Actor  │
   │         │       │         │       │         │
   │ - state │       │ - state │       │ - state │
   │ - heart-│       │ - heart-│       │ - heart-│
   │   beat  │       │   beat  │       │   beat  │
   └────┬────┘       └────┬────┘       └────┬────┘
        │                 │                 │
   ┌────┴────┐       ┌────┴────┐       ┌────┴────┐
   │  Wisp   │       │  Wisp   │       │  Wisp   │
   │   WS    │       │   WS    │       │   WS    │
   │  Conn   │       │  Conn   │       │  Conn   │
   └─────────┘       └─────────┘       └─────────┘
```

### Socket Actor Lifecycle

```
                     ┌──────────────────┐
                     │   WS Connected   │
                     └────────┬─────────┘
                              │
                              ▼
                     ┌──────────────────┐
                     │  Authenticate    │
                     │  (optional)      │
                     └────────┬─────────┘
                              │
              ┌───────────────┼───────────────┐
              │ Auth OK       │               │ Auth Failed
              ▼               │               ▼
     ┌────────────────┐       │      ┌────────────────┐
     │ Socket Actor   │       │      │  Close with    │
     │   Started      │       │      │  4001/4003     │
     └───────┬────────┘       │      └────────────────┘
             │                │
             ▼                │
     ┌────────────────┐       │
     │   Waiting for  │◄──────┘
     │   phx_join     │
     └───────┬────────┘
             │
             │ join("room:lobby", payload)
             ▼
     ┌────────────────┐
     │ Channel.join() │
     └───────┬────────┘
             │
     ┌───────┴───────┐
     │               │
     ▼ JoinOk       ▼ JoinError
┌──────────┐   ┌──────────────┐
│ Subscri- │   │ phx_reply    │
│ bed to   │   │ error        │
│ topic    │   └──────────────┘
└────┬─────┘
     │
     ▼
┌──────────────────────────────────────┐
│           Active State               │
│                                      │
│  ┌─────────────┐  ┌──────────────┐  │
│  │ handle_in   │  │ handle_info  │  │
│  │ (client)    │  │ (server)     │  │
│  └─────────────┘  └──────────────┘  │
│                                      │
│  ┌─────────────┐  ┌──────────────┐  │
│  │ heartbeat   │  │ broadcast    │  │
│  │ ping/pong   │  │ receive      │  │
│  └─────────────┘  └──────────────┘  │
└──────────────────┬───────────────────┘
                   │
                   │ disconnect / leave / error
                   ▼
          ┌────────────────┐
          │   terminate()  │
          │   cleanup      │
          │   presence     │
          └────────────────┘
```

---

## Wire Protocol (Phoenix-Compatible)

Messages use the Phoenix wire format for client compatibility:

```json
[join_ref, ref, topic, event, payload]
```

| Field      | Type            | Description                           |
|------------|-----------------|---------------------------------------|
| `join_ref` | `string\|null`  | Reference from join, for reply routing|
| `ref`      | `string\|null`  | Message reference for reply matching  |
| `topic`    | `string`        | Topic name (e.g., "room:lobby")       |
| `event`    | `string`        | Event name (e.g., "phx_join", "msg")  |
| `payload`  | `object`        | Event payload                         |

### Reserved Events

| Event         | Direction | Description                    |
|---------------|-----------|--------------------------------|
| `phx_join`    | C → S     | Join a channel                 |
| `phx_leave`   | C → S     | Leave a channel                |
| `phx_reply`   | S → C     | Reply to client message        |
| `phx_error`   | S → C     | Channel crashed                |
| `phx_close`   | S → C     | Channel closed                 |
| `heartbeat`   | C ↔ S     | Keepalive ping/pong            |
| `presence_state` | S → C  | Full presence list             |
| `presence_diff`  | S → C  | Presence changes               |

---

## Implementation Phases

### Phase 1: Core (MVP)

- [ ] Socket type with typed assigns
- [ ] Channel behavior/interface with builder pattern
- [ ] Topic pattern parsing and matching
- [ ] Basic PubSub actor (local, single-node)
- [ ] Socket registry actor
- [ ] Wisp WebSocket integration
- [ ] Phoenix wire protocol encoding/decoding
- [ ] broadcast/broadcast_from/push
- [ ] Heartbeat handling
- [ ] Basic error handling and cleanup

**Deliverable:** Working channels for single-node deployments

**Test:** Port levee's DocumentChannel to beryl

### Phase 2: Presence

- [ ] Presence tracking actor
- [ ] presence_state / presence_diff events
- [ ] Auto-cleanup on disconnect
- [ ] Multi-device support (multiple presences per key)
- [ ] Presence list sync on join

**Deliverable:** "Who's online" functionality

### Phase 3: Production Hardening

- [ ] Socket supervision (DynamicSupervisor)
- [ ] Rate limiting per socket/channel
- [ ] Connection limiting per IP
- [ ] Graceful shutdown
- [ ] Telemetry/metrics hooks
- [ ] Channel interceptors/middleware

**Deliverable:** Production-ready single-node

### Phase 4: Distribution

- [ ] Distributed PubSub using `pg` (Erlang process groups)
- [ ] Optional Redis adapter for non-BEAM clusters
- [ ] Presence CRDT for distributed state

**Deliverable:** Multi-node cluster support

### Phase 5: Ecosystem

- [ ] JavaScript client library (or phoenix.js adapter)
- [ ] Long-polling fallback transport
- [ ] Channel versioning
- [ ] Message batching/coalescing

---

## Example: Document Channel for Levee

```gleam
// levee/src/levee/channels/document_channel.gleam

import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/json.{type Json}
import gleam/option.{type Option, None, Some}
import beryl.{type Channels}
import beryl/channel.{type Channel, type HandleResult, type JoinResult}
import beryl/socket.{type Socket}
import levee/auth/jwt
import levee/documents/session
import levee/protocol/message

/// Socket assigns for document channel
pub type DocumentAssigns {
  DocumentAssigns(
    tenant_id: String,
    document_id: String,
    client_id: String,
    user_id: String,
    mode: ConnectionMode,
    claims: jwt.Claims,
    session: session.Session,
  )
}

pub type ConnectionMode {
  ReadMode
  WriteMode
}

/// Messages from document session
pub type SessionMessage {
  OpBroadcast(ops: List(message.Op))
  SignalBroadcast(signals: List(message.Signal))
  SessionClosed(reason: String)
}

/// Create the document channel handler
pub fn new() -> Channel(DocumentAssigns, SessionMessage) {
  channel.new(join)
  |> channel.with_handle_in(handle_in)
  |> channel.with_handle_info(handle_info)
  |> channel.with_terminate(terminate)
}

fn join(
  topic: String,
  payload: Json,
  socket: Socket(DocumentAssigns),
) -> JoinResult(DocumentAssigns) {
  // Topic format: "document:{tenant_id}:{document_id}"
  case parse_document_topic(topic) {
    Error(_) ->
      channel.JoinError(json.object([
        #("error", json.string("invalid_topic")),
      ]))

    Ok(#(tenant_id, document_id)) -> {
      // Validate JWT token from payload
      case validate_connect_message(payload, tenant_id, document_id) {
        Error(reason) ->
          channel.JoinError(json.object([
            #("error", json.string(reason)),
          ]))

        Ok(#(claims, mode, client_info)) -> {
          // Get or create document session
          case session.get_or_create(tenant_id, document_id) {
            Error(_) ->
              channel.JoinError(json.object([
                #("error", json.string("session_unavailable")),
              ]))

            Ok(doc_session) -> {
              // Join the session
              case session.client_join(doc_session, client_info) {
                Error(reason) ->
                  channel.JoinError(json.object([
                    #("error", json.string(reason)),
                  ]))

                Ok(#(client_id, response)) -> {
                  let assigns = DocumentAssigns(
                    tenant_id: tenant_id,
                    document_id: document_id,
                    client_id: client_id,
                    user_id: claims.user_id,
                    mode: mode,
                    claims: claims,
                    session: doc_session,
                  )

                  channel.JoinOk(
                    reply: Some(encode_connect_response(response)),
                    socket: socket.set_assigns(socket, assigns),
                  )
                }
              }
            }
          }
        }
      }
    }
  }
}

fn handle_in(
  event: String,
  payload: Json,
  socket: Socket(DocumentAssigns),
) -> HandleResult(DocumentAssigns) {
  let assigns = socket.get_assigns(socket)

  case event {
    "submitOp" -> handle_submit_op(payload, socket, assigns)
    "submitSignal" -> handle_submit_signal(payload, socket, assigns)
    "noop" -> handle_noop(payload, socket, assigns)
    "requestOps" -> handle_request_ops(payload, socket, assigns)
    _ -> channel.NoReply(socket)
  }
}

fn handle_submit_op(
  payload: Json,
  socket: Socket(DocumentAssigns),
  assigns: DocumentAssigns,
) -> HandleResult(DocumentAssigns) {
  case assigns.mode {
    ReadMode -> {
      push_nack(socket, 403, "InvalidScopeError", "Read-only mode")
      channel.NoReply(socket)
    }
    WriteMode -> {
      case message.decode_submit_op(payload) {
        Error(_) -> {
          push_nack(socket, 400, "BadRequestError", "Invalid submitOp")
          channel.NoReply(socket)
        }
        Ok(submit) -> {
          case session.submit_ops(assigns.session, assigns.client_id, submit.batches) {
            Ok(_) -> channel.NoReply(socket)
            Error(nacks) -> {
              beryl.push(socket, "nack", encode_nacks(nacks))
              channel.NoReply(socket)
            }
          }
        }
      }
    }
  }
}

fn handle_info(
  message: SessionMessage,
  socket: Socket(DocumentAssigns),
) -> HandleResult(DocumentAssigns) {
  case message {
    OpBroadcast(ops) -> {
      beryl.push(socket, "op", encode_ops(ops))
      channel.NoReply(socket)
    }
    SignalBroadcast(signals) -> {
      beryl.push(socket, "signal", encode_signals(signals))
      channel.NoReply(socket)
    }
    SessionClosed(reason) -> {
      beryl.push(socket, "session_closed", json.object([
        #("reason", json.string(reason)),
      ]))
      channel.Stop(channel.Shutdown)
    }
  }
}

fn terminate(reason: channel.StopReason, socket: Socket(DocumentAssigns)) -> Nil {
  let assigns = socket.get_assigns(socket)
  session.client_leave(assigns.session, assigns.client_id)
  Nil
}

// Helper functions...
fn parse_document_topic(topic: String) -> Result(#(String, String), Nil)
fn validate_connect_message(payload: Json, tenant: String, doc: String) -> Result(...)
fn push_nack(socket: Socket(a), code: Int, type_: String, msg: String) -> Nil
// ... etc
```

---

## Dependencies

```toml
# beryl/gleam.toml

[dependencies]
gleam_stdlib = ">= 0.44.0"
gleam_erlang = ">= 0.29.0"
gleam_otp = ">= 0.12.0"
gleam_json = ">= 2.0.0"

# Local path to wisp fork with PR #144
wisp = { path = "../wisp" }

[dev-dependencies]
gleeunit = ">= 1.0.0"
```

---

## Open Questions (Resolved)

| Question | Decision |
|----------|----------|
| **Naming** | `beryl` for discoverability |
| **Message format** | Phoenix format for phoenix.js compatibility |
| **Distributed PubSub** | Wrap `pg` (Erlang process groups) |
| **Presence CRDT** | Start simple (last-write-wins), add CRDT in Phase 4 |
| **JS Client** | Fork/adapt phoenix.js in Phase 5 |
| **Typed assigns** | Yes - `Socket(assigns)` with generic type parameter |

---

## References

- [Phoenix Channels Docs](https://hexdocs.pm/phoenix/channels.html)
- [Phoenix.Presence](https://hexdocs.pm/phoenix/Phoenix.Presence.html)
- [Phoenix PubSub](https://hexdocs.pm/phoenix_pubsub/Phoenix.PubSub.html)
- [Wisp PR #144 - WebSocket Support](https://github.com/gleam-wisp/wisp/pull/144)
- [Erlang pg module](https://www.erlang.org/doc/man/pg.html)
