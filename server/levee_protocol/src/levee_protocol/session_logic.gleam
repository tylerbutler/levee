/// Pure business logic for document collaboration sessions
///
/// These functions extract the decision-making logic from the Elixir
/// session GenServer into type-safe Gleam. They are pure functions
/// with no side effects (no IO, no process communication).
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

// =============================================================================
// Feature Negotiation
// =============================================================================

/// Negotiate features between server and client capabilities.
/// Returns a map of features that both sides agree on.
///
/// Rules:
/// - Server supports (true), client supports (true) -> true
/// - Server supports (true), client doesn't specify -> true (advertise)
/// - Server supports (true), client declines (false) -> false
/// - Otherwise -> server value
pub fn negotiate_features(
  server_features: Dict(String, Bool),
  client_features: Dict(String, Bool),
) -> Dict(String, Bool) {
  dict.map_values(server_features, fn(feature, server_value) {
    case server_value, dict.get(client_features, feature) {
      True, Ok(True) -> True
      True, Error(_) -> True
      True, Ok(False) -> False
      _, _ -> server_value
    }
  })
}

// =============================================================================
// Version Negotiation
// =============================================================================

/// Negotiate protocol version based on client's supported version ranges.
/// Returns the first server version that matches any client version range.
/// Falls back to "0.1.0" if no match found.
pub fn negotiate_version(
  supported_versions: List(String),
  client_versions: List(String),
) -> String {
  case
    list.find(supported_versions, fn(sv) {
      // Simple check: does any client version range contain this version's prefix?
      // e.g., "^0.1.0" matches supported "^0.1.0"
      list.contains(client_versions, sv)
    })
  {
    Ok("^0.1.0") -> "0.1.0"
    Ok("^1.0.0") -> "1.0.0"
    Ok(v) -> v
    Error(_) -> "0.1.0"
  }
}

// =============================================================================
// Summarize Validation
// =============================================================================

/// Validate that summarize operation contents have all required fields.
/// Returns Ok(Nil) if valid, Error with missing field names if not.
pub fn validate_summarize_contents(
  contents: Dict(String, Dynamic),
) -> Result(Nil, String) {
  let required = ["handle", "message", "parents", "head"]

  let missing =
    list.filter(required, fn(field) {
      case dict.get(contents, field) {
        Ok(_) -> False
        Error(_) -> True
      }
    })

  case missing {
    [] -> Ok(Nil)
    _ -> Error("missing fields: " <> string.join(missing, ", "))
  }
}

// =============================================================================
// Signal Recipients
// =============================================================================

/// Determine which clients should receive a signal based on targeting rules.
///
/// Priority: targeted_clients > ignored_clients > single target > broadcast
///
/// - targeted_clients: send only to specified clients (excluding sender)
/// - ignored_clients: send to all except ignored and sender
/// - single_target: send only to the target (if in all_clients and not sender)
/// - broadcast: send to all except sender
pub fn determine_signal_recipients(
  sender_client_id: String,
  targeted_clients: Option(List(String)),
  ignored_clients: Option(List(String)),
  single_target: Option(String),
  all_client_ids: List(String),
) -> List(String) {
  case targeted_clients, ignored_clients, single_target {
    // V2 with targetedClients: send only to specified clients (excluding sender)
    Some(targets), _, _ ->
      targets
      |> list.filter(fn(c) { c != sender_client_id })
      |> list.filter(fn(c) { list.contains(all_client_ids, c) })

    // V2 with ignoredClients: send to all except ignored and sender
    None, Some(ignored), _ ->
      all_client_ids
      |> list.filter(fn(c) {
        c != sender_client_id && !list.contains(ignored, c)
      })

    // V2 with single targetClientId
    None, None, Some(target) ->
      case target != sender_client_id && list.contains(all_client_ids, target) {
        True -> [target]
        False -> []
      }

    // V1 or V2 broadcast: send to all except sender
    None, None, None ->
      list.filter(all_client_ids, fn(c) { c != sender_client_id })
  }
}

// =============================================================================
// History Management
// =============================================================================

/// Add an operation to the history (newest first) and trim to max size.
pub fn add_to_history(op: a, history: List(a), max_size: Int) -> List(a) {
  [op, ..history]
  |> list.take(max_size)
}

// =============================================================================
// Wire Format Builders
// =============================================================================

/// Build a sequenced operation map for the wire format.
/// Takes the original op fields and server-assigned values.
pub type SequencedOpParams {
  SequencedOpParams(
    client_id: String,
    sequence_number: Int,
    minimum_sequence_number: Int,
    client_sequence_number: Int,
    reference_sequence_number: Int,
    op_type: String,
    contents: Dynamic,
    metadata: Dynamic,
    timestamp: Int,
  )
}

/// Build a sequenced op as a list of key-value pairs.
/// The caller converts this to a map in their native format.
pub fn build_sequenced_op(params: SequencedOpParams) -> List(#(String, Dynamic)) {
  [
    #("clientId", coerce(params.client_id)),
    #("sequenceNumber", coerce(params.sequence_number)),
    #("minimumSequenceNumber", coerce(params.minimum_sequence_number)),
    #("clientSequenceNumber", coerce(params.client_sequence_number)),
    #("referenceSequenceNumber", coerce(params.reference_sequence_number)),
    #("type", coerce(params.op_type)),
    #("contents", params.contents),
    #("metadata", params.metadata),
    #("timestamp", coerce(params.timestamp)),
  ]
}

/// Build a summary ack as a list of key-value pairs.
pub fn build_summary_ack(
  handle: String,
  sn: Int,
  msn: Int,
  timestamp: Int,
) -> List(#(String, Dynamic)) {
  let summary_proposal =
    dict.from_list([#("summarySequenceNumber", coerce(sn))])

  let contents =
    dict.from_list([
      #("handle", coerce(handle)),
      #("summaryProposal", coerce(summary_proposal)),
    ])

  [
    #("clientId", coerce(Nil)),
    #("sequenceNumber", coerce(sn + 1)),
    #("minimumSequenceNumber", coerce(msn)),
    #("clientSequenceNumber", coerce(-1)),
    #("referenceSequenceNumber", coerce(sn)),
    #("type", coerce("summaryAck")),
    #("contents", coerce(contents)),
    #("metadata", coerce(Nil)),
    #("timestamp", coerce(timestamp)),
  ]
}

/// Unsafe coerce a value to Dynamic - only used for BEAM interop
/// where we need to build mixed-type maps
@external(erlang, "gleam_stdlib", "identity")
fn coerce(value: a) -> Dynamic
