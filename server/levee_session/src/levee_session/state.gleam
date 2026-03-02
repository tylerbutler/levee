//// Session state types.

import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Monitor, type Pid, type Subject}
import gleam/option.{type Option}
import levee_protocol/sequencing.{type SequenceState}

/// Per-document session state managed by the actor.
pub type SessionState {
  SessionState(
    tenant_id: String,
    document_id: String,
    sequence_state: SequenceState,
    /// Connected clients keyed by client_id
    clients: Dict(String, ClientInfo),
    /// Counter for generating unique client IDs
    client_counter: Int,
    /// Recent operations for delta catch-up (newest first)
    op_history: List(Dynamic),
    /// Latest acknowledged summary info
    latest_summary: Option(SummaryContext),
    /// The actor's own Subject, needed for rebuilding selectors
    subject: Subject(SessionMessage),
  )
}

/// Information about a connected client.
pub type ClientInfo {
  ClientInfo(
    /// The channel handler PID to send ops/signals to
    pid: Pid,
    /// Client metadata from connect_document
    client: Dynamic,
    /// Connection mode: "read" or "write"
    mode: String,
    /// Process monitor for automatic cleanup on disconnect
    monitor: Monitor,
    /// Last sequence number seen by this client
    last_seen_sn: Int,
    /// Negotiated feature flags
    features: Dict(String, Bool),
  )
}

/// Summary context for the latest acknowledged summary.
pub type SummaryContext {
  SummaryContext(handle: String, sequence_number: Int)
}

/// Result of a client_join operation.
pub type ClientJoinResult {
  JoinOk(client_id: String, response: Dynamic)
  JoinError(reason: String)
}

/// Result of submitting operations.
pub type SubmitOpsResult {
  OpsOk
  OpsError(nacks: Dynamic)
}

/// Session message types — the actor's input.
pub type SessionMessage {
  // Calls (require reply)
  ClientJoin(
    connect_msg: Dynamic,
    handler_pid: Pid,
    reply_to: Subject(ClientJoinResult),
  )
  SubmitOps(
    client_id: String,
    batches: Dynamic,
    reply_to: Subject(SubmitOpsResult),
  )
  GetOpsSince(since_sn: Int, reply_to: Subject(List(Dynamic)))
  GetStateSummary(reply_to: Subject(Dynamic))
  GetSummaryContext(reply_to: Subject(Option(SummaryContext)))

  // Casts (fire-and-forget)
  ClientLeave(client_id: String)
  SubmitSignals(client_id: String, batches: Dynamic)
  UpdateClientRsn(client_id: String, rsn: Int)

  // Internal (from monitor selector)
  ClientDown(pid: Pid)
}
