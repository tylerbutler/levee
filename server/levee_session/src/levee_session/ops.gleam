//// Operation processing — sequencing, nacks, broadcasting.

import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/process.{type Pid}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import levee_protocol
import levee_protocol/nack
import levee_protocol/sequencing.{SequenceError, SequenceOk}
import levee_protocol/session_logic
import levee_session/state.{type ClientInfo, type SessionState, SessionState}

// ── FFI ────────────────────────────────────────────────────────────────────

@external(erlang, "session_ffi", "raw_send")
fn raw_send(pid: Pid, msg: a) -> Nil

@external(erlang, "session_ffi", "system_time_ms")
fn system_time_ms() -> Int

/// Unsafe coerce — used to create Dynamic values from typed data.
@external(erlang, "gleam_stdlib", "identity")
pub fn coerce(val: a) -> b

// ── Dynamic field access helpers ───────────────────────────────────────────

pub fn get_string_field(value: Dynamic, key: String, default: String) -> String {
  let decoder = {
    use v <- decode.optional_field(key, default, decode.string)
    decode.success(v)
  }
  case decode.run(value, decoder) {
    Ok(v) -> v
    Error(_) -> default
  }
}

pub fn get_int_field(value: Dynamic, key: String, default: Int) -> Int {
  let decoder = {
    use v <- decode.optional_field(key, default, decode.int)
    decode.success(v)
  }
  case decode.run(value, decoder) {
    Ok(v) -> v
    Error(_) -> default
  }
}

pub fn get_dynamic_field(value: Dynamic, key: String) -> Dynamic {
  let nil_dynamic: Dynamic = coerce(Nil)
  let decoder = {
    use v <- decode.optional_field(key, nil_dynamic, decode.dynamic)
    decode.success(v)
  }
  case decode.run(value, decoder) {
    Ok(v) -> v
    Error(_) -> nil_dynamic
  }
}

pub fn get_map_field(value: Dynamic, key: String) -> Dict(String, Bool) {
  let decoder = {
    use d <- decode.optional_field(
      key,
      dict.new(),
      decode.dict(decode.string, decode.bool),
    )
    decode.success(d)
  }
  case decode.run(value, decoder) {
    Ok(d) -> d
    Error(_) -> dict.new()
  }
}

pub fn get_sn(op: Dynamic) -> Int {
  get_int_field(op, "sequenceNumber", 0)
}

pub fn int_to_string(value: Int) -> String {
  int.to_string(value)
}

// ── Broadcasting ───────────────────────────────────────────────────────────

/// Broadcast ops to all connected clients.
pub fn broadcast_ops(
  document_id: String,
  ops: List(Dynamic),
  clients: Dict(String, ClientInfo),
) -> Nil {
  let message: Dynamic =
    coerce(
      dict.from_list([
        #("documentId", coerce(document_id)),
        #("op", coerce(ops)),
      ]),
    )
  dict.each(clients, fn(_client_id, client_info) {
    raw_send(client_info.pid, #(coerce("op"), message))
  })
}

/// Broadcast a signal to a specific client.
pub fn send_signal(pid: Pid, message: Dynamic) -> Nil {
  raw_send(pid, #(coerce("signal"), message))
}

// ── Op Processing ──────────────────────────────────────────────────────────

/// Process op batches through sequencing.
/// Returns Ok(sequenced_ops, new_state) or Error(nacks, state).
pub fn process_ops(
  client_id: String,
  batches: Dynamic,
  state: SessionState,
  max_history: Int,
) -> Result(#(List(Dynamic), SessionState), #(Dynamic, SessionState)) {
  let ops = flatten_batches(batches)

  let result =
    list.fold(ops, #([], [], state), fn(acc, op) {
      let #(acc_ops, acc_nacks, acc_state) = acc
      let csn = get_int_field(op, "clientSequenceNumber", 0)
      let rsn = get_int_field(op, "referenceSequenceNumber", 0)

      case
        levee_protocol.assign_sequence_number(
          acc_state.sequence_state,
          client_id,
          csn,
          rsn,
        )
      {
        SequenceOk(new_seq_state, assigned_sn, msn) -> {
          let op_type = get_string_field(op, "type", "op")
          case op_type {
            "summarize" ->
              process_summarize_op(
                op,
                client_id,
                assigned_sn,
                msn,
                new_seq_state,
                acc_ops,
                acc_nacks,
                acc_state,
                max_history,
              )
            _ -> {
              let sequenced =
                build_sequenced_op(op, client_id, assigned_sn, msn)
              let updated_history =
                session_logic.add_to_history(
                  sequenced,
                  acc_state.op_history,
                  max_history,
                )
              let new_state =
                SessionState(
                  ..acc_state,
                  sequence_state: new_seq_state,
                  op_history: updated_history,
                )
              #([sequenced, ..acc_ops], acc_nacks, new_state)
            }
          }
        }
        SequenceError(reason) -> {
          let nack_map = build_nack_from_sequence_error(op, reason)
          #(acc_ops, [nack_map, ..acc_nacks], acc_state)
        }
      }
    })

  let #(sequenced_ops, nacks, final_state) = result

  case nacks {
    [] -> Ok(#(list.reverse(sequenced_ops), final_state))
    _ -> Error(#(coerce(list.reverse(nacks)), final_state))
  }
}

fn process_summarize_op(
  op: Dynamic,
  client_id: String,
  assigned_sn: Int,
  msn: Int,
  new_seq_state: levee_protocol.SequenceState,
  acc_ops: List(Dynamic),
  acc_nacks: List(Dynamic),
  acc_state: SessionState,
  max_history: Int,
) -> #(List(Dynamic), List(Dynamic), SessionState) {
  let contents = get_dynamic_field(op, "contents")
  let contents_dict: Dict(String, Dynamic) = coerce(contents)
  case session_logic.validate_summarize_contents(contents_dict) {
    Ok(_) -> {
      let handle = get_string_field(contents, "handle", "")
      let message_field = get_string_field(contents, "message", "")
      let head = get_string_field(contents, "head", "")

      let _ =
        store_summary(
          acc_state.tenant_id,
          acc_state.document_id,
          handle,
          head,
          message_field,
          assigned_sn,
        )

      let summary_ack: Dynamic =
        coerce(session_logic.build_summary_ack(
          handle,
          assigned_sn,
          msn,
          system_time_ms(),
        ))
      let sequenced_summarize =
        build_sequenced_op(op, client_id, assigned_sn, msn)

      let updated_history =
        session_logic.add_to_history(
          summary_ack,
          session_logic.add_to_history(
            sequenced_summarize,
            acc_state.op_history,
            max_history,
          ),
          max_history,
        )

      let new_state =
        SessionState(
          ..acc_state,
          sequence_state: new_seq_state,
          op_history: updated_history,
          latest_summary: Some(state.SummaryContext(
            handle: handle,
            sequence_number: assigned_sn,
          )),
        )

      #([summary_ack, sequenced_summarize, ..acc_ops], acc_nacks, new_state)
    }
    Error(reason) -> {
      let nack_map =
        nack.bad_request("Invalid summarize op: " <> reason, None)
        |> nack_to_wire_map(coerce(Nil))
      #(acc_ops, [nack_map, ..acc_nacks], acc_state)
    }
  }
}

fn store_summary(
  tenant_id: String,
  document_id: String,
  handle: String,
  head: String,
  message: String,
  sequence_number: Int,
) -> Nil {
  let summary: Dynamic =
    coerce(
      dict.from_list([
        #("handle", coerce(handle)),
        #("sequence_number", coerce(sequence_number)),
        #("tree_sha", coerce(head)),
        #("commit_sha", coerce(Nil)),
        #("parent_handle", coerce(Nil)),
        #("message", coerce(message)),
      ]),
    )
  let _ = levee_storage_ets_store_summary(tenant_id, document_id, summary)
  Nil
}

@external(erlang, "session_ffi", "store_summary")
fn levee_storage_ets_store_summary(
  tenant_id: String,
  document_id: String,
  summary: Dynamic,
) -> Dynamic

fn flatten_batches(batches: Dynamic) -> List(Dynamic) {
  case decode.run(batches, decode.list(decode.list(decode.dynamic))) {
    Ok(nested) -> list.flatten(nested)
    Error(_) -> {
      case decode.run(batches, decode.list(decode.dynamic)) {
        Ok(flat) -> flat
        Error(_) -> []
      }
    }
  }
}

// ── Sequenced Op Building ──────────────────────────────────────────────────

fn build_sequenced_op(
  op: Dynamic,
  client_id: String,
  sn: Int,
  msn: Int,
) -> Dynamic {
  let csn = get_int_field(op, "clientSequenceNumber", 0)
  let rsn = get_int_field(op, "referenceSequenceNumber", 0)
  let op_type = get_string_field(op, "type", "op")
  let contents = get_dynamic_field(op, "contents")
  let metadata = get_dynamic_field(op, "metadata")

  let params =
    session_logic.SequencedOpParams(
      client_id: client_id,
      sequence_number: sn,
      minimum_sequence_number: msn,
      client_sequence_number: csn,
      reference_sequence_number: rsn,
      op_type: op_type,
      contents: contents,
      metadata: metadata,
      timestamp: system_time_ms(),
    )

  coerce(session_logic.build_sequenced_op(params))
}

// ── Nack Building ──────────────────────────────────────────────────────────

pub fn nack_unknown_client(client_id: String) -> Dynamic {
  nack.unknown_client(client_id)
  |> nack_to_wire_map(coerce(Nil))
}

pub fn nack_read_only() -> Dynamic {
  nack.read_only_client(None)
  |> nack_to_wire_map(coerce(Nil))
}

fn build_nack_from_sequence_error(
  op: Dynamic,
  reason: sequencing.SequenceError,
) -> Dynamic {
  let nack_val = case reason {
    sequencing.InvalidCsn(expected, received) ->
      nack.invalid_csn(expected, received, None)
    sequencing.InvalidRsn(current_sn, received_rsn) ->
      nack.invalid_rsn(current_sn, received_rsn, None)
    sequencing.UnknownClient(cid) -> nack.unknown_client(cid)
  }
  nack_to_wire_map(nack_val, op)
}

fn nack_to_wire_map(nack_val: nack.Nack, op: Dynamic) -> Dynamic {
  let nack.Nack(_operation, seq_num, content) = nack_val
  let nack.NackContent(code, error_type, message, retry_after) = content

  let content_map =
    dict.from_list([
      #("code", coerce(code)),
      #("type", coerce(nack_error_type_to_string(error_type))),
      #("message", coerce(message)),
    ])

  let content_with_retry = case retry_after {
    Some(seconds) -> dict.insert(content_map, "retryAfter", coerce(seconds))
    None -> content_map
  }

  coerce(
    dict.from_list([
      #("operation", op),
      #("sequenceNumber", coerce(seq_num)),
      #("content", coerce(content_with_retry)),
    ]),
  )
}

fn nack_error_type_to_string(error_type: nack.NackErrorType) -> String {
  case error_type {
    nack.ThrottlingError -> "ThrottlingError"
    nack.InvalidScopeError -> "InvalidScopeError"
    nack.BadRequestError -> "BadRequestError"
    nack.LimitExceededError -> "LimitExceededError"
  }
}

// ── State Summary ──────────────────────────────────────────────────────────

pub fn build_state_summary(state: SessionState) -> Dynamic {
  coerce(
    dict.from_list([
      #("tenant_id", coerce(state.tenant_id)),
      #("document_id", coerce(state.document_id)),
      #("current_sn", coerce(levee_protocol.current_sn(state.sequence_state))),
      #("current_msn", coerce(levee_protocol.current_msn(state.sequence_state))),
      #("client_count", coerce(dict.size(state.clients))),
      #("client_ids", coerce(dict.keys(state.clients))),
      #("history_size", coerce(list.length(state.op_history))),
    ]),
  )
}
