/// Signal handling for Fluid Framework protocol
///
/// Signals are ephemeral messages broadcast to connected clients.
/// Unlike operations, signals are NOT sequenced or persisted.
///
/// This module supports:
/// - Signal v1 (legacy) format: Simple broadcast with address/contents envelope
/// - Signal v2 format: Enhanced format with targeting support (targetedClients, ignoredClients)
/// - System signals: Join/Leave events (server-generated)
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
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

/// Parse a v1 signal envelope from a map
/// The map is expected to have address, contents, and clientBroadcastSignalSequenceNumber
pub fn parse_v1_envelope_from_map(
  raw: Dict(String, Dynamic),
) -> Result(SignalV1Envelope, SignalParseError) {
  case dict.get(raw, "address"), dict.get(raw, "contents") {
    Ok(addr_dyn), Ok(contents_dyn) -> {
      let address = case decode.run(addr_dyn, decode.string) {
        Ok(a) -> a
        Error(_) -> ""
      }

      let contents_map = decode_map(contents_dyn)
      let signal_type = case dict.get(contents_map, "type") {
        Ok(t) ->
          case decode.run(t, decode.string) {
            Ok(s) -> s
            Error(_) -> ""
          }
        Error(_) -> ""
      }
      let content = case dict.get(contents_map, "content") {
        Ok(c) -> c
        Error(_) -> coerce(Nil)
      }

      let seq_num = case dict.get(raw, "clientBroadcastSignalSequenceNumber") {
        Ok(n) ->
          case decode.run(n, decode.int) {
            Ok(i) -> i
            Error(_) -> 0
          }
        Error(_) -> 0
      }

      Ok(SignalV1Envelope(
        address: address,
        contents: SignalV1Contents(signal_type: signal_type, content: content),
        client_broadcast_signal_sequence_number: seq_num,
      ))
    }
    _, _ -> Error(MissingField("address or contents"))
  }
}

// =============================================================================
// Signal Normalization (v1/v2 → internal format)
// =============================================================================

/// Normalized signal format for internal use.
/// All signal formats are converted to this before processing.
pub type NormalizedSignal {
  NormalizedSignal(
    content: Dynamic,
    signal_type: Option(String),
    client_connection_number: Option(Int),
    reference_sequence_number: Option(Int),
    target_client_id: Option(String),
    targeted_clients: Option(List(String)),
    ignored_clients: Option(List(String)),
  )
}

/// Normalize a raw signal map to the internal format.
/// Detects v1 vs v2 based on the presence of "address" or "contents" keys.
pub fn normalize_signal(
  raw: Dict(String, Dynamic),
) -> NormalizedSignal {
  let has_address = dict.has_key(raw, "address")
  let has_contents = dict.has_key(raw, "contents")

  case has_address || has_contents {
    True -> normalize_v1(raw)
    False -> normalize_v2(raw)
  }
}

fn normalize_v1(raw: Dict(String, Dynamic)) -> NormalizedSignal {
  let contents = case dict.get(raw, "contents") {
    Ok(c) -> decode_map(c)
    Error(_) -> dict.new()
  }

  let content_val = case dict.get(contents, "content") {
    Ok(c) -> c
    Error(_) -> coerce(Nil)
  }

  let signal_type = case dict.get(contents, "type") {
    Ok(t) -> decode_optional_string(t)
    Error(_) -> None
  }

  let conn_num = case dict.get(raw, "clientBroadcastSignalSequenceNumber") {
    Ok(n) -> decode_optional_int(n)
    Error(_) -> None
  }

  NormalizedSignal(
    content: content_val,
    signal_type: signal_type,
    client_connection_number: conn_num,
    reference_sequence_number: None,
    target_client_id: None,
    targeted_clients: None,
    ignored_clients: None,
  )
}

fn normalize_v2(raw: Dict(String, Dynamic)) -> NormalizedSignal {
  // Check if this is a wrapper envelope with "signal" key
  let inner = case dict.get(raw, "signal") {
    Ok(s) -> {
      let m = decode_map(s)
      case dict.is_empty(m) {
        True -> raw
        False -> m
      }
    }
    Error(_) -> raw
  }

  let content_val = case dict.get(inner, "content") {
    Ok(c) -> c
    Error(_) -> coerce(Nil)
  }

  let signal_type = case dict.get(inner, "type") {
    Ok(t) -> decode_optional_string(t)
    Error(_) -> None
  }

  let conn_num = case dict.get(inner, "clientConnectionNumber") {
    Ok(n) -> decode_optional_int(n)
    Error(_) -> None
  }

  let rsn = case dict.get(inner, "referenceSequenceNumber") {
    Ok(n) -> decode_optional_int(n)
    Error(_) -> None
  }

  let target_id = case dict.get(inner, "targetClientId") {
    Ok(t) -> decode_optional_string(t)
    Error(_) -> None
  }

  // Targeting from envelope level (not inner signal)
  let targeted = case dict.get(raw, "targetedClients") {
    Ok(t) -> decode_optional_string_list(t)
    Error(_) -> None
  }

  let ignored = case dict.get(raw, "ignoredClients") {
    Ok(i) -> decode_optional_string_list(i)
    Error(_) -> None
  }

  NormalizedSignal(
    content: content_val,
    signal_type: signal_type,
    client_connection_number: conn_num,
    reference_sequence_number: rsn,
    target_client_id: target_id,
    targeted_clients: targeted,
    ignored_clients: ignored,
  )
}

/// Normalize a batch of signals (handles list, single map, or JSON string)
pub fn normalize_signal_batch(
  batch: Dynamic,
) -> List(NormalizedSignal) {
  // Try as list of maps
  case decode.run(batch, decode.list(decode_string_keyed_map())) {
    Ok(maps) -> list.map(maps, normalize_signal)
    Error(_) -> {
      // Try as single map
      case decode.run(batch, decode_string_keyed_map()) {
        Ok(m) -> [normalize_signal(m)]
        Error(_) -> []
      }
    }
  }
}

/// Convert a NormalizedSignal to a Dict for Elixir interop
pub fn normalized_to_map(
  s: NormalizedSignal,
) -> Dict(String, Dynamic) {
  dict.from_list([
    #("content", s.content),
    #("type", option_to_dynamic(s.signal_type)),
    #("clientConnectionNumber", option_to_dynamic(s.client_connection_number)),
    #("referenceSequenceNumber", option_to_dynamic(s.reference_sequence_number)),
    #("targetClientId", option_to_dynamic(s.target_client_id)),
    #("targetedClients", option_to_dynamic(s.targeted_clients)),
    #("ignoredClients", option_to_dynamic(s.ignored_clients)),
  ])
}

fn option_to_dynamic(opt: Option(a)) -> Dynamic {
  case opt {
    Some(v) -> coerce(v)
    None -> coerce(Nil)
  }
}

// Helper decoders

fn decode_optional_string(d: Dynamic) -> Option(String) {
  case decode.run(d, decode.string) {
    Ok(s) -> Some(s)
    Error(_) -> None
  }
}

fn decode_optional_int(d: Dynamic) -> Option(Int) {
  case decode.run(d, decode.int) {
    Ok(n) -> Some(n)
    Error(_) -> None
  }
}

fn decode_optional_string_list(d: Dynamic) -> Option(List(String)) {
  case decode.run(d, decode.list(decode.string)) {
    Ok(l) -> Some(l)
    Error(_) -> None
  }
}

fn decode_map(d: Dynamic) -> Dict(String, Dynamic) {
  case decode.run(d, decode_string_keyed_map()) {
    Ok(m) -> m
    Error(_) -> dict.new()
  }
}

fn decode_string_keyed_map() -> decode.Decoder(Dict(String, Dynamic)) {
  decode.dict(decode.string, decode.dynamic)
}

@external(erlang, "gleam_stdlib", "identity")
fn coerce(value: a) -> Dynamic

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
      |> list.filter(fn(c) {
        c != sender_client_id && !list.contains(ignored, c)
      })
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
pub fn system_signal_message(
  content: Dynamic,
  signal_type: String,
) -> SignalMessage {
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
pub fn detect_signal_version(
  has_address: Bool,
  has_targeted_clients: Bool,
  has_ignored_clients: Bool,
) -> SignalVersion {
  case has_address, has_targeted_clients || has_ignored_clients {
    // Has address field - likely v1
    True, False -> V1Format
    // Has targeting fields - definitely v2
    _, True -> V2Format
    // No address, no targeting - assume v2 (simpler format)
    False, False -> V2Format
  }
}
