//// Beryl - Type-safe real-time communication
////
//// A library for building real-time applications with WebSocket channels,
//// presence tracking, and pub/sub messaging.
////
//// ## Quick Start
////
//// ```gleam
//// import beryl
//// import beryl/channel
//// import beryl/transport/websocket
////
//// pub fn main() {
////   // Start channels system
////   let assert Ok(channels) = beryl.start(beryl.default_config())
////
////   // Register a channel handler
////   let _ = beryl.register(channels, "room:*", room_channel.new())
////
////   // Use with wisp
////   let handler = fn(req) {
////     use <- websocket.upgrade(req, channels.coordinator, websocket.default_config("/socket"))
////     // ... rest of routing
////   }
//// }
//// ```

import beryl/channel.{type Channel}
import beryl/coordinator
import beryl/socket.{type Socket}
import beryl/topic
import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/json
import gleam/list
import gleam/option.{None, Some}

// Re-export types from coordinator for convenience
pub type ChannelHandler =
  coordinator.ChannelHandler

pub type RegisterError =
  coordinator.RegisterError

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
pub fn default_config() -> Config {
  Config(
    heartbeat_interval_ms: 30_000,
    heartbeat_timeout_ms: 60_000,
    max_connections_per_ip: 0,
  )
}

/// Channels system handle
///
/// This is the main entry point for interacting with the channels system.
/// Pass this to channel handlers and the WebSocket transport.
pub type Channels {
  Channels(
    /// The coordinator actor subject - pass to transport.websocket.upgrade()
    coordinator: Subject(coordinator.Message),
    /// Configuration
    config: Config,
  )
}

/// Errors when starting channels
pub type StartError {
  CoordinatorStartFailed
}

/// Start the channels system
///
/// Call once at application startup. Returns a handle that can be passed
/// to the WebSocket transport and used for broadcasting.
///
/// ## Example
///
/// ```gleam
/// pub fn main() {
///   let assert Ok(channels) = beryl.start(beryl.default_config())
///   // Use channels...
/// }
/// ```
pub fn start(config: Config) -> Result(Channels, StartError) {
  case coordinator.start() {
    Error(_) -> Error(CoordinatorStartFailed)
    Ok(coord) -> Ok(Channels(coordinator: coord, config: config))
  }
}

/// Register a channel handler for a topic pattern
///
/// Patterns can be exact matches like "room:lobby" or wildcards like "room:*"
/// which matches any topic starting with "room:".
///
/// ## Example
///
/// ```gleam
/// // Create a typed channel
/// let chat_channel = channel.new(fn(topic, payload, socket) {
///   // Handle join
///   channel.JoinOk(reply: None, socket: socket)
/// })
/// |> channel.with_handle_in(fn(event, payload, socket) {
///   // Handle incoming messages
///   channel.NoReply(socket)
/// })
///
/// // Register it
/// beryl.register(channels, "chat:*", chat_channel)
/// ```
pub fn register(
  channels: Channels,
  pattern: String,
  handler: Channel(assigns, info),
) -> Result(Nil, RegisterError) {
  // Convert typed Channel to type-erased ChannelHandler
  let erased_handler = erase_channel_types(pattern, handler)

  // Register with coordinator
  process.call(channels.coordinator, 5000, fn(reply) {
    coordinator.RegisterChannel(pattern, erased_handler, reply)
  })
}

/// Broadcast a message to all subscribers of a topic
///
/// This sends the message to all sockets subscribed to the topic.
///
/// ## Example
///
/// ```gleam
/// beryl.broadcast(
///   channels,
///   "room:lobby",
///   "new_message",
///   json.object([#("text", json.string("Hello!"))]),
/// )
/// ```
pub fn broadcast(
  channels: Channels,
  topic_name: String,
  event: String,
  payload: json.Json,
) -> Nil {
  process.send(
    channels.coordinator,
    coordinator.Broadcast(topic_name, event, payload, None),
  )
}

/// Broadcast a message to all subscribers except one socket
///
/// Useful for broadcasting a message to everyone except the sender.
///
/// ## Example
///
/// ```gleam
/// // In a channel handler, broadcast to others
/// beryl.broadcast_from(
///   channels,
///   socket_id,
///   "room:lobby",
///   "user_typing",
///   json.object([#("user", json.string("alice"))]),
/// )
/// ```
pub fn broadcast_from(
  channels: Channels,
  except_socket_id: String,
  topic_name: String,
  event: String,
  payload: json.Json,
) -> Nil {
  process.send(
    channels.coordinator,
    coordinator.Broadcast(topic_name, event, payload, Some(except_socket_id)),
  )
}

/// Push a message to a specific socket via its context
///
/// Note: In the lean MVP, this uses the send function from SocketContext.
/// The message is sent directly, not through the coordinator.
pub fn push_to_socket(
  ctx: coordinator.SocketContext,
  event: String,
  payload: json.Json,
) -> Nil {
  let msg =
    json.to_string(
      json.preprocessed_array([
        json.null(),
        json.null(),
        json.string(ctx.topic),
        json.string(event),
        payload,
      ]),
    )
  let _ = ctx.send(msg)
  Nil
}

/// Get the topic ID from a topic using wildcard extraction
///
/// For pattern "room:*" and topic "room:lobby", returns Ok("lobby")
///
/// ## Example
///
/// ```gleam
/// let assert Ok("lobby") = topic.extract_id(topic.Wildcard("room:"), "room:lobby")
/// ```
pub fn extract_topic_id(
  pattern: topic.TopicPattern,
  topic_name: String,
) -> Result(String, Nil) {
  topic.extract_id(pattern, topic_name)
}

// ─────────────────────────────────────────────────────────────────────────────
// Type erasure - Convert typed Channel to ChannelHandler
// ─────────────────────────────────────────────────────────────────────────────

/// Convert a typed Channel to a type-erased ChannelHandler
///
/// This is necessary because we need to store handlers for different
/// channel types in the same registry.
fn erase_channel_types(
  pattern_str: String,
  typed_channel: Channel(assigns, info),
) -> ChannelHandler {
  let pattern = topic.parse_pattern(pattern_str)

  coordinator.ChannelHandler(
    pattern: pattern,
    join: fn(
      topic_name: String,
      payload: Dynamic,
      ctx: coordinator.SocketContext,
    ) {
      // Create a typed socket with Nil assigns (will be set by join)
      let typed_socket = create_socket_from_context(ctx)

      // Decode Dynamic payload to Json for the handler
      let json_payload = dynamic_to_json(payload)

      // Call the typed join handler (unsafe coerce socket to expected type)
      case
        typed_channel.join(
          topic_name,
          json_payload,
          unsafe_coerce_socket(typed_socket),
        )
      {
        channel.JoinOk(reply, new_socket) -> {
          // Extract assigns and type-erase them
          let erased_assigns =
            unsafe_coerce_to_dynamic(socket.get_assigns(new_socket))
          coordinator.JoinOkErased(reply: reply, assigns: erased_assigns)
        }
        channel.JoinError(reason) -> {
          coordinator.JoinErrorErased(reason: reason)
        }
      }
    },
    handle_in: fn(
      event: String,
      payload: Dynamic,
      ctx: coordinator.SocketContext,
    ) {
      // Reconstruct typed socket with current assigns
      let typed_socket = create_socket_with_assigns(ctx)

      // Decode Dynamic payload to Json for the handler
      let json_payload = dynamic_to_json(payload)

      // Call the typed handle_in handler (unsafe coerce socket to expected type)
      case
        typed_channel.handle_in(
          event,
          json_payload,
          unsafe_coerce_socket(typed_socket),
        )
      {
        channel.NoReply(new_socket) -> {
          let erased_assigns =
            unsafe_coerce_to_dynamic(socket.get_assigns(new_socket))
          coordinator.NoReplyErased(assigns: erased_assigns)
        }
        channel.Reply(reply_event, reply_payload, new_socket) -> {
          let erased_assigns =
            unsafe_coerce_to_dynamic(socket.get_assigns(new_socket))
          coordinator.ReplyErased(
            event: reply_event,
            payload: reply_payload,
            assigns: erased_assigns,
          )
        }
        channel.Push(push_event, push_payload, new_socket) -> {
          let erased_assigns =
            unsafe_coerce_to_dynamic(socket.get_assigns(new_socket))
          coordinator.PushErased(
            event: push_event,
            payload: push_payload,
            assigns: erased_assigns,
          )
        }
        channel.Stop(reason) -> {
          coordinator.StopErased(reason: reason)
        }
      }
    },
    terminate: fn(reason: channel.StopReason, ctx: coordinator.SocketContext) {
      let typed_socket = create_socket_with_assigns(ctx)
      // Unsafe coerce socket to expected type
      typed_channel.terminate(reason, unsafe_coerce_socket(typed_socket))
    },
  )
}

/// Create a socket from context with Nil assigns (for join)
fn create_socket_from_context(ctx: coordinator.SocketContext) -> Socket(Nil) {
  let transport =
    socket.Transport(
      send_text: fn(text) {
        ctx.send(text)
        |> result_to_transport_result()
      },
      send_binary: fn(_) { Error(socket.SendFailed("Binary not supported")) },
      close: fn() { Ok(Nil) },
    )

  socket.new(ctx.socket_id, Nil, transport)
}

/// Create a socket from context with existing assigns (type-erased)
fn create_socket_with_assigns(ctx: coordinator.SocketContext) -> Socket(Dynamic) {
  let transport =
    socket.Transport(
      send_text: fn(text) {
        ctx.send(text)
        |> result_to_transport_result()
      },
      send_binary: fn(_) { Error(socket.SendFailed("Binary not supported")) },
      close: fn() { Ok(Nil) },
    )

  socket.new(ctx.socket_id, ctx.assigns, transport)
}

fn result_to_transport_result(
  result: Result(Nil, Nil),
) -> Result(Nil, socket.TransportError) {
  case result {
    Ok(_) -> Ok(Nil)
    Error(_) -> Error(socket.SendFailed("Send failed"))
  }
}

/// Unsafe coercion to Dynamic - only use for type erasure
@external(erlang, "beryl_ffi", "identity")
fn unsafe_coerce_to_dynamic(value: a) -> Dynamic

/// Unsafe coercion of socket types - only use for type erasure
@external(erlang, "beryl_ffi", "identity")
fn unsafe_coerce_socket(socket: Socket(a)) -> Socket(b)

/// Convert Dynamic to Json (best effort)
fn dynamic_to_json(value: Dynamic) -> json.Json {
  // Try string first
  case decode.run(value, decode.string) {
    Ok(s) -> json.string(s)
    Error(_) -> try_decode_int(value)
  }
}

fn try_decode_int(value: Dynamic) -> json.Json {
  case decode.run(value, decode.int) {
    Ok(i) -> json.int(i)
    Error(_) -> try_decode_float(value)
  }
}

fn try_decode_float(value: Dynamic) -> json.Json {
  case decode.run(value, decode.float) {
    Ok(f) -> json.float(f)
    Error(_) -> try_decode_bool(value)
  }
}

fn try_decode_bool(value: Dynamic) -> json.Json {
  case decode.run(value, decode.bool) {
    Ok(b) -> json.bool(b)
    Error(_) -> try_decode_complex(value)
  }
}

fn try_decode_complex(value: Dynamic) -> json.Json {
  // Check for nil/null
  case dynamic.classify(value) {
    "Nil" -> json.null()
    "List" -> {
      case decode.run(value, decode.list(decode.dynamic)) {
        Ok(items) -> json.preprocessed_array(list.map(items, dynamic_to_json))
        Error(_) -> json.null()
      }
    }
    _ -> {
      // Try to decode as a dict/map
      let dict_decoder = decode.dict(decode.string, decode.dynamic)
      case decode.run(value, dict_decoder) {
        Ok(d) -> {
          let pairs =
            d
            |> dict.to_list()
            |> list.map(fn(pair) {
              let #(k, v) = pair
              #(k, dynamic_to_json(v))
            })
          json.object(pairs)
        }
        Error(_) -> json.null()
      }
    }
  }
}
