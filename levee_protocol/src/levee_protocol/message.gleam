/// Protocol message types for WebSocket communication
/// Covers connection, operations, and signals

import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/option.{type Option}

import levee_protocol/types.{
  type Client, type ConnectionMode, type SequencedDocumentMessage,
  type ServiceConfiguration, type SignalClient, type TokenClaims,
}

/// IConnect - sent by client to initiate document collaboration
pub type ConnectMessage {
  ConnectMessage(
    /// Tenant identifier
    tenant_id: String,
    /// Document identifier
    document_id: String,
    /// Authorization token (JWT)
    token: Option(String),
    /// Client details
    client: Client,
    /// Supported protocol versions (semver ranges)
    versions: List(String),
    /// Client driver version
    driver_version: Option(String),
    /// Connection mode (write or read)
    mode: ConnectionMode,
    /// Unique nonce for this connection attempt
    nonce: Option(String),
    /// Expected document epoch
    epoch: Option(String),
    /// Client feature flags
    supported_features: Option(Dict(String, Dynamic)),
    /// Client environment info
    relay_user_agent: Option(String),
  )
}

/// IConnected - sent by server when connection succeeds
pub type ConnectedMessage {
  ConnectedMessage(
    /// Validated token claims
    claims: TokenClaims,
    /// Server-assigned client identifier
    client_id: String,
    /// Document pre-existed (always true for connections)
    existing: Bool,
    /// Maximum message size in bytes
    max_message_size: Int,
    /// Actual connection mode granted
    mode: ConnectionMode,
    /// Service configuration
    service_configuration: ServiceConfiguration,
    /// Currently connected clients
    initial_clients: List(SignalClient),
    /// Initial messages (typically empty)
    initial_messages: List(SequencedDocumentMessage),
    /// Initial signals (typically empty)
    initial_signals: List(SignalMessage),
    /// Server-supported protocol versions
    supported_versions: List(String),
    /// Server-supported features
    supported_features: Dict(String, Dynamic),
    /// Negotiated protocol version
    version: String,
    /// Connection timestamp
    timestamp: Option(Int),
    /// Last known sequence number
    checkpoint_sequence_number: Option(Int),
    /// Document epoch
    epoch: Option(String),
    /// Server environment info
    relay_service_agent: Option(String),
  )
}

/// Connection error response
pub type ConnectError {
  ConnectError(
    /// HTTP-style status code
    code: Int,
    /// Error description
    message: String,
  )
}

/// Signal message (v2 format)
pub type SignalMessage {
  SignalMessage(
    /// Sending client ID (null for server-generated)
    client_id: Option(String),
    /// Signal content
    content: Dynamic,
    /// Signal type
    signal_type: Option(String),
    /// Signal counter
    client_connection_number: Option(Int),
    /// Sequence context
    reference_sequence_number: Option(Int),
    /// Target client (if targeted)
    target_client_id: Option(String),
  )
}

/// Sent signal message (client -> server, v2)
pub type SentSignalMessage {
  SentSignalMessage(
    content: Dynamic,
    signal_type: Option(String),
    client_connection_number: Option(Int),
    reference_sequence_number: Option(Int),
    target_client_id: Option(String),
  )
}

/// Op broadcast message (server -> clients)
pub type OpMessage {
  OpMessage(
    /// Document ID
    document_id: String,
    /// Sequenced operations
    ops: List(SequencedDocumentMessage),
  )
}

/// Message types enumeration
pub type MessageType {
  NoOp
  ClientJoin
  ClientLeave
  Propose
  Reject
  Accept
  Summarize
  SummaryAck
  SummaryNack
  Operation
  NoClient
  RoundTrip
  Control
}

/// Convert message type to wire format string
pub fn message_type_to_string(mt: MessageType) -> String {
  case mt {
    NoOp -> "noop"
    ClientJoin -> "join"
    ClientLeave -> "leave"
    Propose -> "propose"
    Reject -> "reject"
    Accept -> "accept"
    Summarize -> "summarize"
    SummaryAck -> "summaryAck"
    SummaryNack -> "summaryNack"
    Operation -> "op"
    NoClient -> "noClient"
    RoundTrip -> "tripComplete"
    Control -> "control"
  }
}

/// Parse message type from wire format string
pub fn message_type_from_string(s: String) -> Result(MessageType, Nil) {
  case s {
    "noop" -> Ok(NoOp)
    "join" -> Ok(ClientJoin)
    "leave" -> Ok(ClientLeave)
    "propose" -> Ok(Propose)
    "reject" -> Ok(Reject)
    "accept" -> Ok(Accept)
    "summarize" -> Ok(Summarize)
    "summaryAck" -> Ok(SummaryAck)
    "summaryNack" -> Ok(SummaryNack)
    "op" -> Ok(Operation)
    "noClient" -> Ok(NoClient)
    "tripComplete" -> Ok(RoundTrip)
    "control" -> Ok(Control)
    _ -> Error(Nil)
  }
}
