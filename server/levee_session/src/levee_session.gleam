//// Document session actor — manages per-document collaboration state.
////
//// Each document gets one session actor responsible for:
//// - Client tracking (join/leave/monitor)
//// - Sequence number assignment via levee_protocol
//// - Operation broadcast to connected clients
//// - Signal relay with v1/v2 targeting
//// - Operation history for delta catch-up
//// - Summary handling

import bravo
import bravo/uset.{type USet}
import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import levee_protocol
import levee_protocol/sequencing
import levee_session/ops
import levee_session/signals
import levee_session/state.{
  type ClientInfo, type ClientJoinResult, type SessionMessage, type SessionState,
  type SubmitOpsResult, ClientDown, ClientInfo, ClientJoin, ClientLeave,
  GetOpsSince, GetStateSummary, GetSummaryContext, JoinError, JoinOk, OpsError,
  OpsOk, SessionState, SubmitOps, SubmitSignals, UpdateClientRsn,
}
import levee_session/system

// ── Constants ──────────────────────────────────────────────────────────────

// 16 MB
const max_message_size = 16_777_216

// 64 KB
const block_size = 65_536

const max_history_size = 1000

// ── FFI ────────────────────────────────────────────────────────────────────

@external(erlang, "session_ffi", "raw_send")
pub fn raw_send(pid: Pid, msg: a) -> Nil

@external(erlang, "session_ffi", "system_time_ms")
pub fn system_time_ms() -> Int

@external(erlang, "session_ffi", "pid_alive")
fn pid_alive(pid: Pid) -> Bool

// ── Registry (bravo ETS) ───────────────────────────────────────────────────

/// The session registry type — a bravo USet keyed by (tenant_id, doc_id).
pub type SessionRegistry =
  USet(#(String, String), Subject(SessionMessage))

/// Initialize the session registry ETS table.
pub fn init_registry() -> SessionRegistry {
  let assert Ok(table) = uset.new(name: "levee_sessions", access: bravo.Public)
  table
}

/// Look up or create a session for the given tenant/document.
pub fn get_or_create(
  registry: SessionRegistry,
  tenant_id: String,
  document_id: String,
) -> Result(Subject(SessionMessage), actor.StartError) {
  let key = #(tenant_id, document_id)
  case uset.lookup(from: registry, at: key) {
    Ok(subject) -> {
      // Verify the process is still alive
      case process.subject_owner(subject) {
        Ok(pid) ->
          case pid_alive(pid) {
            True -> Ok(subject)
            False -> {
              // Stale entry — clean up and start fresh
              let _ = uset.delete_key(from: registry, at: key)
              start_and_register(registry, key, tenant_id, document_id)
            }
          }
        Error(_) -> start_and_register(registry, key, tenant_id, document_id)
      }
    }
    Error(_) -> start_and_register(registry, key, tenant_id, document_id)
  }
}

fn start_and_register(
  registry: SessionRegistry,
  key: #(String, String),
  tenant_id: String,
  document_id: String,
) -> Result(Subject(SessionMessage), actor.StartError) {
  case start(tenant_id, document_id) {
    Ok(subject) -> {
      let _ = uset.insert(into: registry, key: key, value: subject)
      Ok(subject)
    }
    Error(e) -> Error(e)
  }
}

// ── Actor ──────────────────────────────────────────────────────────────────

/// Start a new session actor for the given tenant/document.
pub fn start(
  tenant_id: String,
  document_id: String,
) -> Result(Subject(SessionMessage), actor.StartError) {
  actor.new_with_initialiser(5000, fn(subject) {
    io.println("Starting session for " <> tenant_id <> "/" <> document_id)

    let sequence_state = levee_protocol.new_sequence_state()
    let latest_summary = load_latest_summary(tenant_id, document_id)

    let initial_state =
      SessionState(
        tenant_id: tenant_id,
        document_id: document_id,
        sequence_state: sequence_state,
        clients: dict.new(),
        client_counter: 0,
        op_history: [],
        latest_summary: latest_summary,
        subject: subject,
      )

    let selector =
      process.new_selector()
      |> process.select(subject)
      |> process.select_monitors(fn(down) {
        case down {
          process.ProcessDown(_monitor, pid, _reason) -> ClientDown(pid)
          process.PortDown(_monitor, _port, _reason) ->
            ClientDown(process.self())
        }
      })

    actor.initialised(initial_state)
    |> actor.selecting(selector)
    |> actor.returning(subject)
    |> Ok
  })
  |> actor.on_message(handle_message)
  |> actor.start
  |> extract_subject
}

fn extract_subject(
  result: Result(actor.Started(Subject(SessionMessage)), actor.StartError),
) -> Result(Subject(SessionMessage), actor.StartError) {
  case result {
    Ok(started) -> Ok(started.data)
    Error(e) -> Error(e)
  }
}

fn load_latest_summary(
  tenant_id: String,
  document_id: String,
) -> Option(state.SummaryContext) {
  case levee_storage_ets_get_latest_summary(tenant_id, document_id) {
    Ok(summary) -> Some(summary)
    Error(_) -> None
  }
}

@external(erlang, "session_ffi", "load_latest_summary")
fn levee_storage_ets_get_latest_summary(
  tenant_id: String,
  document_id: String,
) -> Result(state.SummaryContext, Nil)

// ── Message handler ────────────────────────────────────────────────────────

fn handle_message(
  state: SessionState,
  message: SessionMessage,
) -> actor.Next(SessionState, SessionMessage) {
  case message {
    ClientJoin(connect_msg, handler_pid, reply_to) ->
      handle_client_join(state, connect_msg, handler_pid, reply_to)

    SubmitOps(client_id, batches, reply_to) ->
      handle_submit_ops(state, client_id, batches, reply_to)

    GetOpsSince(since_sn, reply_to) -> {
      let filtered_ops =
        state.op_history
        |> list.filter(fn(op) { ops.get_sn(op) > since_sn })
        |> list.reverse
      process.send(reply_to, filtered_ops)
      actor.continue(state)
    }

    GetStateSummary(reply_to) -> {
      let summary = ops.build_state_summary(state)
      process.send(reply_to, summary)
      actor.continue(state)
    }

    GetSummaryContext(reply_to) -> {
      process.send(reply_to, state.latest_summary)
      actor.continue(state)
    }

    ClientLeave(client_id) -> handle_client_leave(state, client_id)

    SubmitSignals(client_id, batches) -> {
      case dict.get(state.clients, client_id) {
        Error(_) -> actor.continue(state)
        Ok(_) -> {
          signals.broadcast_signals(
            client_id,
            batches,
            state.clients,
            state.document_id,
          )
          actor.continue(state)
        }
      }
    }

    UpdateClientRsn(client_id, rsn) ->
      handle_update_client_rsn(state, client_id, rsn)

    ClientDown(pid) -> handle_client_down(state, pid)
  }
}

// ── Client Join ────────────────────────────────────────────────────────────

fn handle_client_join(
  state: SessionState,
  connect_msg: Dynamic,
  handler_pid: Pid,
  reply_to: Subject(ClientJoinResult),
) -> actor.Next(SessionState, SessionMessage) {
  let client_id = generate_client_id(state)
  let mode = ops.get_string_field(connect_msg, "mode", "write")
  let current_sn = levee_protocol.current_sn(state.sequence_state)

  // Register client in sequence state
  let new_seq_state =
    levee_protocol.client_join(state.sequence_state, client_id, current_sn)

  // Monitor the handler process
  let monitor = process.monitor(handler_pid)

  // Build client info
  let client_features = ops.get_map_field(connect_msg, "supportedFeatures")
  let server_features = dict.from_list([#("submit_signals_v2", True)])
  let negotiated_features =
    levee_protocol.negotiate_features(server_features, client_features)

  let client_info =
    ClientInfo(
      pid: handler_pid,
      client: ops.get_dynamic_field(connect_msg, "client"),
      mode: mode,
      monitor: monitor,
      last_seen_sn: current_sn,
      features: negotiated_features,
    )

  let new_clients = dict.insert(state.clients, client_id, client_info)

  // Generate system join message
  let #(join_message, final_seq_state, updated_history) =
    system.generate_system_message(
      "join",
      client_id,
      ops.get_dynamic_field(connect_msg, "client"),
      new_seq_state,
      state.op_history,
      max_history_size,
    )

  // Build connected response
  let connected_response =
    system.build_connected_response(
      client_id,
      mode,
      connect_msg,
      final_seq_state,
      new_clients,
      state.latest_summary,
      max_message_size,
      block_size,
    )

  // Broadcast join to all clients
  ops.broadcast_ops(state.document_id, [join_message], new_clients)

  let new_state =
    SessionState(
      ..state,
      sequence_state: final_seq_state,
      clients: new_clients,
      client_counter: state.client_counter + 1,
      op_history: updated_history,
    )

  process.send(reply_to, JoinOk(client_id, connected_response))

  // Rebuild selector with updated monitors
  actor.continue(new_state)
  |> actor.with_selector(build_selector(new_state.subject))
}

// ── Submit Ops ─────────────────────────────────────────────────────────────

fn handle_submit_ops(
  state: SessionState,
  client_id: String,
  batches: Dynamic,
  reply_to: Subject(SubmitOpsResult),
) -> actor.Next(SessionState, SessionMessage) {
  case dict.get(state.clients, client_id) {
    Error(_) -> {
      let nack = ops.nack_unknown_client(client_id)
      process.send(reply_to, OpsError(nack))
      actor.continue(state)
    }
    Ok(client_info) -> {
      case client_info.mode {
        "read" -> {
          let nack = ops.nack_read_only()
          process.send(reply_to, OpsError(nack))
          actor.continue(state)
        }
        _ -> {
          case ops.process_ops(client_id, batches, state, max_history_size) {
            Ok(#(sequenced_ops, new_state)) -> {
              ops.broadcast_ops(
                state.document_id,
                sequenced_ops,
                new_state.clients,
              )
              process.send(reply_to, OpsOk)
              actor.continue(new_state)
            }
            Error(#(nacks, new_state)) -> {
              process.send(reply_to, OpsError(nacks))
              actor.continue(new_state)
            }
          }
        }
      }
    }
  }
}

// ── Client Leave ───────────────────────────────────────────────────────────

fn handle_client_leave(
  state: SessionState,
  client_id: String,
) -> actor.Next(SessionState, SessionMessage) {
  case dict.get(state.clients, client_id) {
    Error(_) -> actor.continue(state)
    Ok(client_info) -> {
      // Demonitor
      process.demonitor_process(client_info.monitor)

      // Remove from sequence state
      let new_seq_state =
        levee_protocol.client_leave(state.sequence_state, client_id)
      let new_clients = dict.delete(state.clients, client_id)

      // Generate system leave message
      let #(leave_message, final_seq_state, updated_history) =
        system.generate_system_message(
          "leave",
          client_id,
          ops.coerce(client_id),
          new_seq_state,
          state.op_history,
          max_history_size,
        )

      // Broadcast to remaining clients
      case dict.size(new_clients) > 0 {
        True ->
          ops.broadcast_ops(state.document_id, [leave_message], new_clients)
        False -> {
          io.println(
            "No clients left for "
            <> state.tenant_id
            <> "/"
            <> state.document_id
            <> ", session idle",
          )
          Nil
        }
      }

      let new_state =
        SessionState(
          ..state,
          sequence_state: final_seq_state,
          clients: new_clients,
          op_history: updated_history,
        )

      actor.continue(new_state)
      |> actor.with_selector(build_selector(new_state.subject))
    }
  }
}

// ── Update Client RSN ──────────────────────────────────────────────────────

fn handle_update_client_rsn(
  state: SessionState,
  client_id: String,
  rsn: Int,
) -> actor.Next(SessionState, SessionMessage) {
  case sequencing.update_client_rsn(state.sequence_state, client_id, rsn) {
    Ok(new_seq_state) -> {
      let new_clients = case dict.get(state.clients, client_id) {
        Ok(info) ->
          dict.insert(
            state.clients,
            client_id,
            ClientInfo(..info, last_seen_sn: rsn),
          )
        Error(_) -> state.clients
      }
      actor.continue(
        SessionState(
          ..state,
          sequence_state: new_seq_state,
          clients: new_clients,
        ),
      )
    }
    Error(_) -> actor.continue(state)
  }
}

// ── Client Down (monitor) ──────────────────────────────────────────────────

fn handle_client_down(
  state: SessionState,
  pid: Pid,
) -> actor.Next(SessionState, SessionMessage) {
  // Find client by PID
  let found =
    state.clients
    |> dict.to_list
    |> list.find(fn(entry) { { entry.1 }.pid == pid })

  case found {
    Ok(#(client_id, _)) -> handle_client_leave(state, client_id)
    Error(_) -> actor.continue(state)
  }
}

// ── Helpers ────────────────────────────────────────────────────────────────

fn generate_client_id(state: SessionState) -> String {
  state.tenant_id
  <> "_"
  <> state.document_id
  <> "_"
  <> ops.int_to_string(state.client_counter + 1)
}

fn build_selector(
  subject: Subject(SessionMessage),
) -> process.Selector(SessionMessage) {
  process.new_selector()
  |> process.select(subject)
  |> process.select_monitors(fn(down) {
    case down {
      process.ProcessDown(_monitor, pid, _reason) -> ClientDown(pid)
      process.PortDown(_monitor, _port, _reason) -> ClientDown(process.self())
    }
  })
}
