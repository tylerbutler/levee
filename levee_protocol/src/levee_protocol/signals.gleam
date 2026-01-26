/// Signal handling for Fluid Framework protocol
///
/// Signals are ephemeral messages broadcast to connected clients.
/// Unlike operations, signals are NOT sequenced or persisted.
///
/// This module supports:
/// - Signal v1 (legacy) format: Simple broadcast with address/contents envelope
/// - Signal v2 format: Enhanced format with targeting support (targetedClients, ignoredClients)
/// - System signals: Join/Leave events (server-generated)

import gleam/dynamic.{type Dynamic}
import gleam/list
import gleam/option.{type Option, None, Some}

import levee_protocol/types.{type Client}

// =============================================================================
// System Signal Types
// =============================================================================

/// System signal types (server-generated)
pub type SystemSignalType {
  /// Client joined the session
  ClientJoinSignal
  /// Client left the session
  ClientLeaveSignal
}

/// Signal content for client join
pub type ClientJoinContent {
  ClientJoinContent(client_id: String, client: Client)
}

/// Signal content for client leave
pub type ClientLeaveContent {
  ClientLeaveContent(client_id: String)
}

/// System signal (server-generated)
pub type SystemSignal {
  JoinSignal(ClientJoinContent)
  LeaveSignal(ClientLeaveContent)
}

/// Create a system signal for client join
pub fn client_join_signal(client_id: String, client: Client) -> SystemSignal {
  JoinSignal(ClientJoinContent(client_id: client_id, client: client))
}

/// Create a system signal for client leave
pub fn client_leave_signal(client_id: String) -> SystemSignal {
  LeaveSignal(ClientLeaveContent(client_id: client_id))
}

// =============================================================================
// Signal V1 Format (Legacy)
// =============================================================================

/// Signal addressing for v1 format
pub type SignalAddress {
  /// Broadcast to all clients
  BroadcastAddress
  /// Target specific container (path-based)
  ContainerAddress(String)
}

/// V1 signal envelope (legacy format)
/// Content batches contain JSON-stringified envelope objects
pub type SignalV1Envelope {
  SignalV1Envelope(
    /// Address for routing (typically container path or empty for broadcast)
    address: String,
    /// Signal contents with type and payload
    contents: SignalV1Contents,
    /// Client-assigned signal sequence number
    client_broadcast_signal_sequence_number: Int,
  )
}

/// V1 signal contents
pub type SignalV1Contents {
  SignalV1Contents(
    /// Signal type identifier
    signal_type: String,
    /// Arbitrary signal payload
    content: Dynamic,
  )
}

/// Parse a v1 signal envelope from raw content
/// The content is expected to be a map with address, contents, and sequence number
pub fn parse_v1_envelope(
  _content: Dynamic,
) -> Result(SignalV1Envelope, SignalParseError) {
  // This would normally use dynamic decoders, but for now we return an error
  // as the actual parsing happens in Elixir
  Error(InvalidFormat("V1 parsing should be done in Elixir"))
}

// =============================================================================
// Signal V2 Format (Current)
// =============================================================================

/// V2 signal format with enhanced targeting capabilities
/// Requires `supportedFeatures.submit_signals_v2 = true` on both client and server
pub type SignalV2 {
  SignalV2(
    /// Signal content/payload
    content: Dynamic,
    /// Signal type identifier
    signal_type: Option(String),
    /// Client-assigned signal connection number
    client_connection_number: Option(Int),
    /// Sequence number for ordering context
    reference_sequence_number: Option(Int),
    /// Target specific client (for v2 single-target signals)
    target_client_id: Option(String),
  )
}

/// V2 signal envelope with full targeting support
/// This is the wrapper format for v2 signals with multi-client targeting
pub type ClientBroadcastSignalEnvelope {
  ClientBroadcastSignalEnvelope(
    /// The signal content
    signal: SignalV2,
    /// Optional list of specific client IDs to target
    /// If specified, signal is only sent to these clients
    targeted_clients: Option(List(String)),
    /// Optional list of client IDs to exclude
    /// If specified, signal is NOT sent to these clients
    ignored_clients: Option(List(String)),
  )
}

/// Signal parse error
pub type SignalParseError {
  InvalidFormat(String)
  MissingField(String)
}

// =============================================================================
// Signal Targeting Logic
// =============================================================================

/// Check if a signal is targeted at a specific client
pub fn is_targeted(signal: SignalV2) -> Bool {
  option.is_some(signal.target_client_id)
}

/// Check if a signal should be received by a specific client (v2 single-target)
pub fn should_receive(signal: SignalV2, client_id: String) -> Bool {
  case signal.target_client_id {
    None -> True
    Some(target) -> target == client_id
  }
}

/// Determine the target recipients for a v2 signal envelope
/// Returns the list of client IDs that should receive the signal
pub fn get_signal_recipients(
  envelope: ClientBroadcastSignalEnvelope,
  all_clients: List(String),
  sender_client_id: String,
) -> List(String) {
  case envelope.targeted_clients, envelope.ignored_clients {
    // Targeted clients specified - only send to those (excluding sender)
    Some(targets), _ -> {
      targets
      |> list.filter(fn(c) { c != sender_client_id })
    }

    // Ignored clients specified - send to all except ignored and sender
    None, Some(ignored) -> {
      all_clients
      |> list.filter(fn(c) { c != sender_client_id && !list.contains(ignored, c) })
    }

    // No targeting - broadcast to all except sender
    None, None -> {
      all_clients
      |> list.filter(fn(c) { c != sender_client_id })
    }
  }
}

/// Check if a client should receive a signal based on targeting rules
pub fn should_client_receive_signal(
  envelope: ClientBroadcastSignalEnvelope,
  client_id: String,
  sender_client_id: String,
) -> Bool {
  // Never send to sender
  case client_id == sender_client_id {
    True -> False
    False -> {
      case envelope.targeted_clients, envelope.ignored_clients {
        // Targeted clients - check if in list
        Some(targets), _ -> list.contains(targets, client_id)

        // Ignored clients - check if NOT in list
        None, Some(ignored) -> !list.contains(ignored, client_id)

        // No targeting - receive
        None, None -> True
      }
    }
  }
}

// =============================================================================
// Signal Constructors
// =============================================================================

/// Create a broadcast signal (v2) - sent to all clients
pub fn broadcast(
  content: Dynamic,
  signal_type: Option(String),
  connection_number: Option(Int),
  rsn: Option(Int),
) -> SignalV2 {
  SignalV2(
    content: content,
    signal_type: signal_type,
    client_connection_number: connection_number,
    reference_sequence_number: rsn,
    target_client_id: None,
  )
}

/// Create a targeted signal (v2) - sent to a single specific client
pub fn targeted(
  content: Dynamic,
  target_client_id: String,
  signal_type: Option(String),
  connection_number: Option(Int),
  rsn: Option(Int),
) -> SignalV2 {
  SignalV2(
    content: content,
    signal_type: signal_type,
    client_connection_number: connection_number,
    reference_sequence_number: rsn,
    target_client_id: Some(target_client_id),
  )
}

/// Create a v2 signal envelope for broadcast
pub fn broadcast_envelope(signal: SignalV2) -> ClientBroadcastSignalEnvelope {
  ClientBroadcastSignalEnvelope(
    signal: signal,
    targeted_clients: None,
    ignored_clients: None,
  )
}

/// Create a v2 signal envelope with targeted clients
pub fn targeted_envelope(
  signal: SignalV2,
  targets: List(String),
) -> ClientBroadcastSignalEnvelope {
  ClientBroadcastSignalEnvelope(
    signal: signal,
    targeted_clients: Some(targets),
    ignored_clients: None,
  )
}

/// Create a v2 signal envelope with ignored clients
pub fn ignored_envelope(
  signal: SignalV2,
  ignored: List(String),
) -> ClientBroadcastSignalEnvelope {
  ClientBroadcastSignalEnvelope(
    signal: signal,
    targeted_clients: None,
    ignored_clients: Some(ignored),
  )
}

// =============================================================================
// Signal Message (Server -> Client)
// =============================================================================

/// Signal message sent from server to clients
pub type SignalMessage {
  SignalMessage(
    /// Sending client ID (nil for server-generated signals)
    client_id: Option(String),
    /// Signal content
    content: Dynamic,
    /// Signal type
    signal_type: Option(String),
    /// Client connection number
    client_connection_number: Option(Int),
    /// Reference sequence number
    reference_sequence_number: Option(Int),
    /// Target client ID (if targeted)
    target_client_id: Option(String),
  )
}

/// Create a signal message from a v2 signal
pub fn signal_message_from_v2(
  sender_client_id: String,
  signal: SignalV2,
) -> SignalMessage {
  SignalMessage(
    client_id: Some(sender_client_id),
    content: signal.content,
    signal_type: signal.signal_type,
    client_connection_number: signal.client_connection_number,
    reference_sequence_number: signal.reference_sequence_number,
    target_client_id: signal.target_client_id,
  )
}

/// Create a system signal message (for join/leave)
pub fn system_signal_message(content: Dynamic, signal_type: String) -> SignalMessage {
  SignalMessage(
    client_id: None,
    content: content,
    signal_type: Some(signal_type),
    client_connection_number: None,
    reference_sequence_number: None,
    target_client_id: None,
  )
}

// =============================================================================
// Signal Version Detection
// =============================================================================

/// Detected signal format version
pub type SignalVersion {
  /// Legacy v1 format with envelope wrapper
  V1Format
  /// Current v2 format with targeting support
  V2Format
  /// Unknown/invalid format
  UnknownFormat
}

/// Heuristic to detect signal format version
/// V1 signals typically have: address, contents, clientBroadcastSignalSequenceNumber
/// V2 signals typically have: content, type, clientConnectionNumber, referenceSequenceNumber
/// V2 with targeting has: targetedClients or ignoredClients
pub fn detect_signal_version(has_address: Bool, has_targeted_clients: Bool, has_ignored_clients: Bool) -> SignalVersion {
  case has_address, has_targeted_clients || has_ignored_clients {
    // Has address field - likely v1
    True, False -> V1Format
    // Has targeting fields - definitely v2
    _, True -> V2Format
    // No address, no targeting - assume v2 (simpler format)
    False, False -> V2Format
  }
}
