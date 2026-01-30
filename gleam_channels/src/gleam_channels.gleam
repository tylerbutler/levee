//// Gleam Channels - Type-safe real-time communication
////
//// A library for building real-time applications with WebSocket channels,
//// presence tracking, and pub/sub messaging.
////
//// ## Quick Start
////
//// ```gleam
//// import gleam_channels
//// import gleam_channels/channel
//// import gleam_channels/transport/websocket
////
//// pub fn main() {
////   // Start channels system
////   let assert Ok(channels) = gleam_channels.start(gleam_channels.default_config())
////
////   // Register a channel handler
////   let _ = gleam_channels.register(channels, "room:*", room_channel.new())
////
////   // Use with wisp
////   let handler = fn(req) {
////     use <- websocket.upgrade(req, channels, websocket.default_config("/socket"))
////     // ... rest of routing
////   }
//// }
//// ```

import gleam/erlang/process.{type Subject}
import gleam/json.{type Json}
import gleam/option.{type Option}

// Re-export submodules for convenience
// pub const socket = gleam_channels/socket
// pub const channel = gleam_channels/channel
// pub const presence = gleam_channels/presence

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

/// Channels system handle (opaque to hide internal actor)
pub opaque type Channels {
  Channels(
    subject: Subject(ChannelsMessage),
    config: Config,
  )
}

/// Internal message type for channels actor
pub type ChannelsMessage {
  // Channel registration
  RegisterChannel(
    pattern: String,
    handler: ChannelHandler,
    reply: Subject(Result(Nil, RegisterError)),
  )
  // Socket management
  SocketConnected(socket_id: String, socket_subject: Subject(SocketMessage))
  SocketDisconnected(socket_id: String)
  // Broadcast
  Broadcast(topic: String, event: String, payload: Json, except: Option(String))
  // Topic lookup
  GetHandler(topic: String, reply: Subject(Option(ChannelHandler)))
}

/// Type-erased channel handler for storage
/// The actual typed Channel is converted to this for the registry
pub type ChannelHandler {
  ChannelHandler(
    join: fn(String, Json, SocketRef) -> JoinResultErased,
    handle_in: fn(String, Json, SocketRef) -> HandleResultErased,
    terminate: fn(String, SocketRef) -> Nil,
  )
}

/// Type-erased results (Dynamic state stored internally)
pub type JoinResultErased {
  JoinOkErased(reply: Option(Json))
  JoinErrorErased(reason: Json)
}

pub type HandleResultErased {
  NoReplyErased
  ReplyErased(event: String, payload: Json)
  PushErased(event: String, payload: Json)
  StopErased(reason: String)
}

/// Reference to a socket (for handlers)
pub opaque type SocketRef {
  SocketRef(
    id: String,
    subject: Subject(SocketMessage),
    channels: Subject(ChannelsMessage),
  )
}

/// Messages to individual sockets
pub type SocketMessage {
  SendMessage(event: String, payload: Json)
  JoinTopic(topic: String)
  LeaveTopic(topic: String)
  Close(reason: String)
}

/// Errors when starting channels
pub type StartError {
  PubSubStartFailed
  RegistryStartFailed
}

/// Errors when registering channels
pub type RegisterError {
  PatternAlreadyRegistered(String)
  InvalidPattern(String)
}

/// Start the channels system
///
/// Call once at application startup. Returns a handle that can be passed
/// to the WebSocket transport and used for broadcasting.
pub fn start(config: Config) -> Result(Channels, StartError) {
  // TODO: Start the channels actor with pubsub, registry, etc.
  // For now, return a placeholder
  Error(PubSubStartFailed)
}

/// Register a channel handler for a topic pattern
///
/// Patterns can be exact matches like "room:lobby" or wildcards like "room:*"
/// which matches any topic starting with "room:".
///
/// ## Example
///
/// ```gleam
/// gleam_channels.register(channels, "room:*", room_channel.new())
/// gleam_channels.register(channels, "user:*", user_channel.new())
/// ```
pub fn register(
  channels: Channels,
  pattern: String,
  handler: ChannelHandler,
) -> Result(Nil, RegisterError) {
  process.call(channels.subject, 5000, fn(reply) {
    RegisterChannel(pattern, handler, reply)
  })
}

/// Broadcast a message to all subscribers of a topic
///
/// ## Example
///
/// ```gleam
/// gleam_channels.broadcast(channels, "room:lobby", "new_message", payload)
/// ```
pub fn broadcast(
  channels: Channels,
  topic: String,
  event: String,
  payload: Json,
) -> Nil {
  process.send(channels.subject, Broadcast(topic, event, payload, option.None))
}

/// Broadcast a message to all subscribers except one socket
///
/// Useful for broadcasting a message to everyone except the sender.
pub fn broadcast_from(
  channels: Channels,
  except_socket_id: String,
  topic: String,
  event: String,
  payload: Json,
) -> Nil {
  process.send(
    channels.subject,
    Broadcast(topic, event, payload, option.Some(except_socket_id)),
  )
}

/// Push a message to a specific socket
pub fn push(socket_ref: SocketRef, event: String, payload: Json) -> Nil {
  process.send(socket_ref.subject, SendMessage(event, payload))
}

/// Get the topic ID from a topic using the registered pattern
///
/// For pattern "room:*" and topic "room:lobby", returns Ok("lobby")
pub fn topic_id(channels: Channels, topic: String) -> Result(String, Nil) {
  // TODO: Implement pattern matching and ID extraction
  Error(Nil)
}

/// Get the socket ID from a socket reference
pub fn socket_id(socket_ref: SocketRef) -> String {
  socket_ref.id
}
