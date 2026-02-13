//// WebSocket Transport - Wisp integration for beryl
////
//// This module provides the bridge between Wisp's WebSocket handling
//// and the beryl coordinator. It handles:
//// - WebSocket connection lifecycle
//// - Phoenix wire protocol parsing
//// - Routing messages to/from the coordinator

import gleam/bit_array
import gleam/crypto
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Subject}
import gleam/option.{type Option, None}
import gleam/result
import beryl/coordinator.{type Message as CoordinatorMessage}
import beryl/wire
import wisp
import wisp/websocket

/// Get current process PID as Dynamic (for handler_pid in SocketConnected)
@external(erlang, "beryl_ffi", "identity")
fn unsafe_coerce(value: a) -> Dynamic

fn get_self() -> Dynamic {
  unsafe_coerce(process.self())
}

/// Configuration for the WebSocket transport
pub type TransportConfig {
  TransportConfig(
    /// URL path to match for WebSocket upgrade (e.g., "/socket")
    path: String,
  )
}

/// Create a default transport config
pub fn default_config(path: String) -> TransportConfig {
  TransportConfig(path: path)
}

/// State maintained per WebSocket connection
type ConnectionState {
  ConnectionState(socket_id: String, coordinator: Subject(CoordinatorMessage))
}

/// Upgrade a request to WebSocket if it matches the configured path
///
/// Usage in your Wisp router:
/// ```gleam
/// fn handle_request(req: Request, channels: Channels) -> Response {
///   use <- websocket.upgrade(req, channels.coordinator, websocket.default_config("/socket"))
///   // Fall through to regular HTTP routing
///   case wisp.path_segments(req) {
///     [] -> index_page()
///     _ -> wisp.not_found()
///   }
/// }
/// ```
pub fn upgrade(
  request: wisp.Request,
  coordinator: Subject(CoordinatorMessage),
  config: TransportConfig,
  next: fn() -> wisp.Response,
) -> wisp.Response {
  // Check if path matches
  let path = "/" <> wisp.path_segments(request) |> string_join("/")

  case path == config.path {
    False -> next()
    True -> {
      // Upgrade to WebSocket
      wisp.websocket(
        request,
        on_init: fn(connection) { on_init(connection, coordinator) },
        on_message: on_message,
        on_close: on_close,
      )
    }
  }
}

/// Alternative: upgrade any request to WebSocket (caller handles path matching)
pub fn upgrade_connection(
  request: wisp.Request,
  coordinator: Subject(CoordinatorMessage),
) -> wisp.Response {
  wisp.websocket(
    request,
    on_init: fn(connection) { on_init(connection, coordinator) },
    on_message: on_message,
    on_close: on_close,
  )
}

/// Initialize WebSocket connection
fn on_init(
  connection: websocket.Connection,
  coordinator: Subject(CoordinatorMessage),
) -> #(ConnectionState, Option(process.Selector(a))) {
  // Generate unique socket ID
  let socket_id = generate_socket_id()

  // Create send function that the coordinator can use
  let send_fn = fn(text: String) -> Result(Nil, Nil) {
    websocket.send_text(connection, text)
    |> result.replace(Nil)
    |> result.replace_error(Nil)
  }

  // Register with coordinator (in wisp transport, self() is the handler)
  let handler_pid = get_self()
  process.send(
    coordinator,
    coordinator.SocketConnected(socket_id, send_fn, handler_pid),
  )

  let state = ConnectionState(socket_id: socket_id, coordinator: coordinator)

  // No custom selector needed for MVP
  #(state, None)
}

/// Handle incoming WebSocket messages
fn on_message(
  state: ConnectionState,
  message: websocket.Message(a),
  _connection: websocket.Connection,
) -> websocket.Next(ConnectionState) {
  case message {
    websocket.Text(text) -> {
      handle_text_message(state, text)
      websocket.Continue(state)
    }
    websocket.Binary(_) -> {
      // Binary messages not supported in Phoenix protocol
      websocket.Continue(state)
    }
    websocket.Closed -> {
      websocket.Stop
    }
    websocket.Shutdown -> {
      websocket.Stop
    }
    websocket.Custom(_) -> {
      websocket.Continue(state)
    }
  }
}

/// Handle text messages (Phoenix wire protocol)
fn handle_text_message(state: ConnectionState, text: String) -> Nil {
  case wire.decode_message(text) {
    Error(_) -> {
      // Invalid message - ignore (could log in production)
      Nil
    }
    Ok(msg) -> {
      route_wire_message(state, msg)
    }
  }
}

/// Route parsed wire message to appropriate coordinator action
fn route_wire_message(state: ConnectionState, msg: wire.WireMessage) -> Nil {
  case msg.event {
    "phx_join" -> {
      let ref = option.unwrap(msg.ref, "")
      process.send(
        state.coordinator,
        coordinator.Join(
          state.socket_id,
          msg.topic,
          msg.payload,
          msg.join_ref,
          ref,
        ),
      )
    }

    "phx_leave" -> {
      process.send(
        state.coordinator,
        coordinator.Leave(state.socket_id, msg.topic, msg.ref),
      )
    }

    "heartbeat" -> {
      let ref = option.unwrap(msg.ref, "")
      process.send(
        state.coordinator,
        coordinator.Heartbeat(state.socket_id, ref),
      )
    }

    // Regular channel event
    _ -> {
      process.send(
        state.coordinator,
        coordinator.HandleIn(
          state.socket_id,
          msg.topic,
          msg.event,
          msg.payload,
          msg.ref,
        ),
      )
    }
  }
}

/// Cleanup when connection closes
fn on_close(state: ConnectionState) -> Nil {
  process.send(
    state.coordinator,
    coordinator.SocketDisconnected(state.socket_id),
  )
}

/// Generate a unique socket ID
fn generate_socket_id() -> String {
  let bytes = crypto.strong_random_bytes(16)
  bytes_to_hex(bytes)
}

/// Convert bytes to hex string
fn bytes_to_hex(bytes: BitArray) -> String {
  bytes
  |> bit_array.base16_encode()
}

/// Helper to join path segments
fn string_join(segments: List(String), separator: String) -> String {
  case segments {
    [] -> ""
    [first, ..rest] -> {
      list_fold(rest, first, fn(acc, segment) { acc <> separator <> segment })
    }
  }
}

fn list_fold(list: List(a), acc: b, f: fn(b, a) -> b) -> b {
  case list {
    [] -> acc
    [first, ..rest] -> list_fold(rest, f(acc, first), f)
  }
}
