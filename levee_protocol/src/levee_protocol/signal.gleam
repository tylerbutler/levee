/// Signal handling for Fluid Framework protocol
///
/// Signals are ephemeral messages broadcast to connected clients.
/// Unlike operations, signals are NOT sequenced or persisted.

import gleam/dynamic.{type Dynamic}
import gleam/option.{type Option, None, Some}

import levee_protocol/types.{type Client}

/// System signal types
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

/// Create a system signal for client join
pub fn client_join_signal(client_id: String, client: Client) -> SystemSignal {
  JoinSignal(ClientJoinContent(client_id: client_id, client: client))
}

/// Create a system signal for client leave
pub fn client_leave_signal(client_id: String) -> SystemSignal {
  LeaveSignal(ClientLeaveContent(client_id: client_id))
}

/// System signal (server-generated)
pub type SystemSignal {
  JoinSignal(ClientJoinContent)
  LeaveSignal(ClientLeaveContent)
}

/// Signal addressing for v1 format
pub type SignalAddress {
  /// Broadcast to all clients
  BroadcastAddress
  /// Target specific container (path-based)
  ContainerAddress(String)
}

/// V1 signal envelope (legacy format)
pub type SignalV1Envelope {
  SignalV1Envelope(
    address: String,
    contents: SignalV1Contents,
    client_broadcast_signal_sequence_number: Int,
  )
}

/// V1 signal contents
pub type SignalV1Contents {
  SignalV1Contents(signal_type: String, content: Dynamic)
}

/// V2 signal (current format)
pub type SignalV2 {
  SignalV2(
    content: Dynamic,
    signal_type: Option(String),
    client_connection_number: Option(Int),
    reference_sequence_number: Option(Int),
    target_client_id: Option(String),
  )
}

/// Check if a signal is targeted at a specific client
pub fn is_targeted(signal: SignalV2) -> Bool {
  option.is_some(signal.target_client_id)
}

/// Check if a signal should be received by a specific client
pub fn should_receive(signal: SignalV2, client_id: String) -> Bool {
  case signal.target_client_id {
    None -> True
    Some(target) -> target == client_id
  }
}

/// Create a broadcast signal (v2)
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

/// Create a targeted signal (v2)
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
