//// System messages (join/leave) and connected response building.

import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option, None, Some}
import levee_protocol
import levee_protocol/sequencing.{type SequenceState}
import levee_protocol/session_logic
import levee_session/ops
import levee_session/state.{type ClientInfo, type SummaryContext}

// ── FFI ────────────────────────────────────────────────────────────────────

@external(erlang, "session_ffi", "system_time_ms")
fn system_time_ms() -> Int

@external(erlang, "session_ffi", "system_time_s")
fn system_time_s() -> Int

@external(erlang, "session_ffi", "json_encode_to_string")
fn json_encode_to_string(term: a) -> String

/// Unsafe coerce for building Dynamic values.
@external(erlang, "gleam_stdlib", "identity")
fn coerce(val: a) -> b

// ── System Messages ────────────────────────────────────────────────────────

/// Generate a system message (join/leave) with proper sequencing.
/// Returns (message, updated_sequence_state, updated_history).
pub fn generate_system_message(
  message_type: String,
  client_id: String,
  content: Dynamic,
  sequence_state: SequenceState,
  history: List(Dynamic),
  max_history: Int,
) -> #(Dynamic, SequenceState, List(Dynamic)) {
  let current_sn = levee_protocol.current_sn(sequence_state)
  let new_sn = current_sn + 1
  let msn = levee_protocol.current_msn(sequence_state)

  // Build message content based on type
  let message_content: Dynamic = case message_type {
    "join" ->
      coerce(
        dict.from_list([
          #("clientId", coerce(client_id)),
          #("detail", content),
        ]),
      )
    _ -> content
  }

  let system_message: Dynamic =
    coerce(
      dict.from_list([
        #("clientId", coerce(Nil)),
        #("sequenceNumber", coerce(new_sn)),
        #("minimumSequenceNumber", coerce(msn)),
        #("clientSequenceNumber", coerce(-1)),
        #("referenceSequenceNumber", coerce(current_sn)),
        #("type", coerce(message_type)),
        #("contents", message_content),
        #("metadata", coerce(Nil)),
        #("timestamp", coerce(system_time_ms())),
        #("data", coerce(json_encode_to_string(message_content))),
      ]),
    )

  // Update sequence state
  let updated_seq_state =
    levee_protocol.sequence_state_from_checkpoint(new_sn, msn)

  // Re-register all clients
  let connected = levee_protocol.connected_clients(sequence_state)
  let final_seq_state =
    list.fold(connected, updated_seq_state, fn(acc, cid) {
      levee_protocol.client_join(acc, cid, new_sn)
    })

  // Add to history
  let updated_history =
    session_logic.add_to_history(system_message, history, max_history)

  #(system_message, final_seq_state, updated_history)
}

// ── Connected Response ─────────────────────────────────────────────────────

const supported_versions = ["^0.1.0", "^1.0.0"]

/// Build the IConnected response sent to clients on connect_document_success.
pub fn build_connected_response(
  client_id: String,
  mode: String,
  connect_msg: Dynamic,
  sequence_state: SequenceState,
  clients: Dict(String, ClientInfo),
  latest_summary: Option(SummaryContext),
  max_message_size: Int,
  block_size: Int,
) -> Dynamic {
  let current_sn = levee_protocol.current_sn(sequence_state)

  // Build initial clients list (all except the joining one)
  let initial_clients: List(Dynamic) =
    clients
    |> dict.delete(client_id)
    |> dict.to_list
    |> list.map(fn(entry) {
      let #(cid, info) = entry
      coerce(
        dict.from_list([
          #("clientId", coerce(cid)),
          #("client", info.client),
          #("mode", coerce(info.mode)),
        ]),
      )
    })

  // Negotiate features
  let client_features = ops.get_map_field(connect_msg, "supportedFeatures")
  let server_features = dict.from_list([#("submit_signals_v2", True)])
  let negotiated_features =
    levee_protocol.negotiate_features(server_features, client_features)

  // Negotiate version
  let client_versions = get_string_list(connect_msg, "versions")
  let negotiated_version =
    levee_protocol.negotiate_version(supported_versions, client_versions)

  // Build mock claims
  let claims = build_mock_claims(connect_msg)

  let base_response: Dict(String, Dynamic) =
    dict.from_list([
      #("claims", coerce(claims)),
      #("clientId", coerce(client_id)),
      #("existing", coerce(True)),
      #("maxMessageSize", coerce(max_message_size)),
      #("mode", coerce(mode)),
      #(
        "serviceConfiguration",
        coerce(
          dict.from_list([
            #("blockSize", coerce(block_size)),
            #("maxMessageSize", coerce(max_message_size)),
          ]),
        ),
      ),
      #("initialClients", coerce(initial_clients)),
      #("initialMessages", coerce([])),
      #("initialSignals", coerce([])),
      #("supportedVersions", coerce(supported_versions)),
      #("supportedFeatures", coerce(negotiated_features)),
      #("version", coerce(negotiated_version)),
      #("checkpointSequenceNumber", coerce(current_sn)),
    ])

  // Add summary context if available
  let response = case latest_summary {
    Some(ctx) ->
      dict.insert(
        base_response,
        "summaryContext",
        coerce(
          dict.from_list([
            #("handle", coerce(ctx.handle)),
            #("sequenceNumber", coerce(ctx.sequence_number)),
          ]),
        ),
      )
    None -> base_response
  }

  coerce(response)
}

fn build_mock_claims(connect_msg: Dynamic) -> Dynamic {
  let now = system_time_s()
  let client_field = ops.get_dynamic_field(connect_msg, "client")
  coerce(
    dict.from_list([
      #("documentId", coerce(ops.get_string_field(connect_msg, "id", ""))),
      #("scopes", coerce(["doc:read", "doc:write"])),
      #("tenantId", coerce(ops.get_string_field(connect_msg, "tenantId", ""))),
      #("user", ops.get_dynamic_field(client_field, "user")),
      #("iat", coerce(now)),
      #("exp", coerce(now + 3600)),
      #("ver", coerce("1.0")),
    ]),
  )
}

fn get_string_list(value: Dynamic, key: String) -> List(String) {
  let decoder = {
    use lst <- decode.optional_field(key, [], decode.list(decode.string))
    decode.success(lst)
  }
  case decode.run(value, decoder) {
    Ok(lst) -> lst
    Error(_) -> []
  }
}
