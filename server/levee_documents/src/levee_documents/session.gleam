//// Document collaboration session actor.
////
//// This module ports the Elixir `Levee.Documents.Session` GenServer into a
//// typed Gleam actor. Transport delivery is intentionally abstract: websocket
//// processes subscribe with a `Subject(Broadcast)`, and the session emits
//// `OpsBroadcast` / `SignalBroadcast` values without depending on beryl/mist.

import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import levee_documents/time
import levee_protocol/nack
import levee_protocol/sequencing
import levee_protocol/session_logic
import levee_storage
import levee_storage/types

pub const max_message_size = 16_777_216

pub const block_size = 65_536

pub const max_history_size = 1000

pub type Mode {
  Read
  Write
}

pub type Connect {
  Connect(
    client: Dynamic,
    mode: Mode,
    supported_features: Dict(String, Bool),
    versions: List(String),
  )
}

pub type Operation {
  Operation(
    client_sequence_number: Int,
    reference_sequence_number: Int,
    message_type: String,
    contents: Dynamic,
    metadata: Option(Dynamic),
  )
}

pub type SequencedOp {
  SequencedOp(
    client_id: Option(String),
    sequence_number: Int,
    minimum_sequence_number: Int,
    client_sequence_number: Int,
    reference_sequence_number: Int,
    message_type: String,
    contents: Dynamic,
    metadata: Option(Dynamic),
    timestamp: Int,
    data: Option(String),
  )
}

pub type InitialClient {
  InitialClient(client_id: String, client: Dynamic, mode: Mode)
}

pub type SummaryContext {
  SummaryContext(handle: String, sequence_number: Int)
}

pub type Connected {
  Connected(
    client_id: String,
    existing: Bool,
    max_message_size: Int,
    mode: Mode,
    service_configuration: ServiceConfiguration,
    initial_clients: List(InitialClient),
    initial_messages: List(SequencedOp),
    supported_versions: List(String),
    supported_features: Dict(String, Bool),
    version: String,
    checkpoint_sequence_number: Int,
    summary_context: Option(SummaryContext),
  )
}

pub type ServiceConfiguration {
  ServiceConfiguration(block_size: Int, max_message_size: Int)
}

pub type Signal {
  Signal(
    content: Dynamic,
    targeted_clients: Option(List(String)),
    ignored_clients: Option(List(String)),
    target_client_id: Option(String),
  )
}

pub type SignalMessage {
  SignalMessage(client_id: String, content: Dynamic)
}

pub type Broadcast {
  OpsBroadcast(document_id: String, ops: List(SequencedOp))
  SignalBroadcast(message: SignalMessage)
}

pub type StateSummary {
  StateSummary(
    tenant_id: String,
    document_id: String,
    current_sn: Int,
    current_msn: Int,
    client_count: Int,
    client_ids: List(String),
    history_size: Int,
  )
}

pub type SessionError {
  UnknownClient(String)
  ReadOnlyClient
  SequenceRejected(List(nack.Nack))
  StorageFailed(types.StorageError)
}

pub type Message {
  ClientJoin(Connect, Subject(Result(Connected, SessionError)))
  ClientLeave(String)
  SubmitOps(
    String,
    List(Operation),
    Subject(Result(List(SequencedOp), SessionError)),
  )
  SubmitSignals(String, List(Signal))
  GetOpsSince(Int, Subject(Result(List(SequencedOp), SessionError)))
  UpdateClientRsn(String, Int)
  GetStateSummary(Subject(Result(StateSummary, SessionError)))
  GetSummaryContext(Subject(Result(Option(SummaryContext), SessionError)))
  Subscribe(String, Subject(Broadcast), Subject(Nil))
  Unsubscribe(String)
  Shutdown(Subject(Nil))
}

pub type StartArgs {
  StartArgs(
    tables: levee_storage.Tables,
    tenant_id: String,
    document_id: String,
  )
}

type ClientInfo {
  ClientInfo(
    client: Dynamic,
    mode: Mode,
    last_seen_sn: Int,
    features: Dict(String, Bool),
    subscriber: Option(Subject(Broadcast)),
  )
}

type State {
  State(
    tables: levee_storage.Tables,
    tenant_id: String,
    document_id: String,
    sequence_state: sequencing.SequenceState,
    clients: Dict(String, ClientInfo),
    client_counter: Int,
    op_history: List(SequencedOp),
    latest_summary: Option(SummaryContext),
  )
}

pub fn start(args: StartArgs) -> actor.StartResult(Subject(Message)) {
  actor.new_with_initialiser(5000, fn(subject) {
    let latest_summary =
      load_latest_summary(args.tables, args.tenant_id, args.document_id)
    let sequence_state = case latest_summary {
      Some(summary) ->
        sequencing.from_checkpoint(
          summary.sequence_number,
          summary.sequence_number,
        )
      None -> sequencing.new()
    }
    let op_history = case latest_summary {
      Some(summary) ->
        case
          levee_storage.ets_get_deltas(
            args.tables,
            args.tenant_id,
            args.document_id,
            summary.sequence_number,
            None,
            max_history_size,
          )
        {
          Ok(deltas) ->
            deltas |> list.map(delta_to_sequenced_op) |> list.reverse
          Error(_) -> []
        }
      None -> []
    }
    actor.initialised(State(
      tables: args.tables,
      tenant_id: args.tenant_id,
      document_id: args.document_id,
      sequence_state: sequence_state,
      clients: dict.new(),
      client_counter: 0,
      op_history: op_history,
      latest_summary: latest_summary,
    ))
    |> actor.returning(subject)
    |> Ok
  })
  |> actor.on_message(handle_message)
  |> actor.start
}

pub fn client_join(
  actor: Subject(Message),
  connect: Connect,
) -> Result(Connected, SessionError) {
  process.call(actor, 5000, fn(reply) { ClientJoin(connect, reply) })
}

pub fn client_leave(actor: Subject(Message), client_id: String) -> Nil {
  process.send(actor, ClientLeave(client_id))
}

pub fn submit_ops(
  actor: Subject(Message),
  client_id: String,
  ops: List(Operation),
) -> Result(List(SequencedOp), SessionError) {
  process.call(actor, 5000, fn(reply) { SubmitOps(client_id, ops, reply) })
}

pub fn submit_signals(
  actor: Subject(Message),
  client_id: String,
  signals: List(Signal),
) -> Nil {
  process.send(actor, SubmitSignals(client_id, signals))
}

pub fn get_ops_since(
  actor: Subject(Message),
  since_sn: Int,
) -> Result(List(SequencedOp), SessionError) {
  process.call(actor, 5000, fn(reply) { GetOpsSince(since_sn, reply) })
}

pub fn update_client_rsn(
  actor: Subject(Message),
  client_id: String,
  rsn: Int,
) -> Nil {
  process.send(actor, UpdateClientRsn(client_id, rsn))
}

pub fn get_state_summary(
  actor: Subject(Message),
) -> Result(StateSummary, SessionError) {
  process.call(actor, 5000, fn(reply) { GetStateSummary(reply) })
}

pub fn get_summary_context(
  actor: Subject(Message),
) -> Result(Option(SummaryContext), SessionError) {
  process.call(actor, 5000, fn(reply) { GetSummaryContext(reply) })
}

pub fn subscribe(
  actor: Subject(Message),
  client_id: String,
  subscriber: Subject(Broadcast),
) -> Nil {
  process.call(actor, 5000, fn(reply) {
    Subscribe(client_id, subscriber, reply)
  })
}

pub fn unsubscribe(actor: Subject(Message), client_id: String) -> Nil {
  process.send(actor, Unsubscribe(client_id))
}

fn handle_message(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    ClientJoin(connect, reply_to) -> {
      let client_id = generate_client_id(state)
      let current_sn = sequencing.current_sn(state.sequence_state)
      let sequence_state =
        sequencing.client_join(state.sequence_state, client_id, current_sn)
      let features =
        session_logic.negotiate_features(
          supported_features(),
          connect.supported_features,
        )
      let clients =
        dict.insert(
          state.clients,
          client_id,
          ClientInfo(
            client: connect.client,
            mode: connect.mode,
            last_seen_sn: current_sn,
            features: features,
            subscriber: None,
          ),
        )
      let #(join_message, sequence_state, op_history) =
        generate_system_message(
          "join",
          client_id,
          connect.client,
          sequence_state,
          state.op_history,
          state,
        )
      let response =
        build_connected_response(
          client_id,
          connect,
          State(
            ..state,
            sequence_state: sequence_state,
            clients: clients,
            op_history: op_history,
          ),
        )
      broadcast_ops(state.document_id, [join_message], clients)
      process.send(reply_to, Ok(response))
      actor.continue(
        State(
          ..state,
          sequence_state: sequence_state,
          clients: clients,
          client_counter: state.client_counter + 1,
          op_history: op_history,
        ),
      )
    }

    ClientLeave(client_id) -> {
      case dict.get(state.clients, client_id) {
        Error(_) -> actor.continue(state)
        Ok(_) -> {
          let sequence_state =
            sequencing.client_leave(state.sequence_state, client_id)
          let clients = dict.delete(state.clients, client_id)
          let #(leave_message, sequence_state, op_history) =
            generate_system_message(
              "leave",
              client_id,
              dynamic.string(client_id),
              sequence_state,
              state.op_history,
              state,
            )
          broadcast_ops(state.document_id, [leave_message], clients)
          actor.continue(
            State(
              ..state,
              sequence_state: sequence_state,
              clients: clients,
              op_history: op_history,
            ),
          )
        }
      }
    }

    SubmitOps(client_id, ops, reply_to) -> {
      case dict.get(state.clients, client_id) {
        Error(_) -> {
          process.send(reply_to, Error(UnknownClient(client_id)))
          actor.continue(state)
        }
        Ok(ClientInfo(mode: Read, ..)) -> {
          process.send(reply_to, Error(ReadOnlyClient))
          actor.continue(state)
        }
        Ok(_) -> {
          let #(result, new_state) = process_ops(client_id, ops, state)
          case result {
            Ok(sequenced_ops) ->
              broadcast_ops(state.document_id, sequenced_ops, new_state.clients)
            Error(_) -> Nil
          }
          process.send(reply_to, result)
          actor.continue(new_state)
        }
      }
    }

    SubmitSignals(client_id, signals) -> {
      case dict.has_key(state.clients, client_id) {
        False -> actor.continue(state)
        True -> {
          list.each(signals, fn(signal) {
            broadcast_signal(client_id, signal, state.clients)
          })
          actor.continue(state)
        }
      }
    }

    GetOpsSince(since_sn, reply_to) -> {
      let ops =
        state.op_history
        |> list.filter(fn(op) { op.sequence_number > since_sn })
        |> list.reverse
      process.send(reply_to, Ok(ops))
      actor.continue(state)
    }

    UpdateClientRsn(client_id, rsn) -> {
      case sequencing.update_client_rsn(state.sequence_state, client_id, rsn) {
        Error(_) -> actor.continue(state)
        Ok(sequence_state) -> {
          let clients = case dict.get(state.clients, client_id) {
            Ok(info) ->
              dict.insert(
                state.clients,
                client_id,
                ClientInfo(..info, last_seen_sn: rsn),
              )
            Error(_) -> state.clients
          }
          actor.continue(
            State(..state, sequence_state: sequence_state, clients: clients),
          )
        }
      }
    }

    GetStateSummary(reply_to) -> {
      process.send(
        reply_to,
        Ok(StateSummary(
          tenant_id: state.tenant_id,
          document_id: state.document_id,
          current_sn: sequencing.current_sn(state.sequence_state),
          current_msn: sequencing.current_msn(state.sequence_state),
          client_count: dict.size(state.clients),
          client_ids: dict.keys(state.clients),
          history_size: list.length(state.op_history),
        )),
      )
      actor.continue(state)
    }

    GetSummaryContext(reply_to) -> {
      process.send(reply_to, Ok(state.latest_summary))
      actor.continue(state)
    }

    Subscribe(client_id, subscriber, reply_to) -> {
      let clients = case dict.get(state.clients, client_id) {
        Ok(info) ->
          dict.insert(
            state.clients,
            client_id,
            ClientInfo(..info, subscriber: Some(subscriber)),
          )
        Error(_) -> state.clients
      }
      process.send(reply_to, Nil)
      actor.continue(State(..state, clients: clients))
    }

    Unsubscribe(client_id) -> {
      let clients = case dict.get(state.clients, client_id) {
        Ok(info) ->
          dict.insert(
            state.clients,
            client_id,
            ClientInfo(..info, subscriber: None),
          )
        Error(_) -> state.clients
      }
      actor.continue(State(..state, clients: clients))
    }

    Shutdown(reply_to) -> {
      process.send(reply_to, Nil)
      actor.stop()
    }
  }
}

fn supported_features() -> Dict(String, Bool) {
  dict.from_list([#("submit_signals_v2", True)])
}

fn supported_versions() -> List(String) {
  ["^0.1.0", "^1.0.0"]
}

fn generate_client_id(state: State) -> String {
  state.tenant_id
  <> "_"
  <> state.document_id
  <> "_"
  <> int.to_string(state.client_counter + 1)
}

fn build_connected_response(
  client_id: String,
  connect: Connect,
  state: State,
) -> Connected {
  let initial_clients =
    state.clients
    |> dict.delete(client_id)
    |> dict.to_list
    |> list.map(fn(entry) {
      let #(id, info) = entry
      InitialClient(client_id: id, client: info.client, mode: info.mode)
    })

  Connected(
    client_id: client_id,
    existing: True,
    max_message_size: max_message_size,
    mode: connect.mode,
    service_configuration: ServiceConfiguration(
      block_size: block_size,
      max_message_size: max_message_size,
    ),
    initial_clients: initial_clients,
    initial_messages: list.reverse(state.op_history),
    supported_versions: supported_versions(),
    supported_features: session_logic.negotiate_features(
      supported_features(),
      connect.supported_features,
    ),
    version: session_logic.negotiate_version(
      supported_versions(),
      connect.versions,
    ),
    checkpoint_sequence_number: sequencing.current_sn(state.sequence_state),
    summary_context: state.latest_summary,
  )
}

fn process_ops(
  client_id: String,
  ops: List(Operation),
  state: State,
) -> #(Result(List(SequencedOp), SessionError), State) {
  let #(sequenced, nacks, final_state) =
    list.fold(ops, #([], [], state), fn(acc, op) {
      let #(acc_ops, acc_nacks, acc_state) = acc
      case
        sequencing.assign_sequence_number(
          acc_state.sequence_state,
          client_id,
          op.client_sequence_number,
          op.reference_sequence_number,
        )
      {
        sequencing.SequenceOk(sequence_state, assigned_sn, msn) ->
          case op.message_type == "summarize" {
            True ->
              process_summarize_op(
                op,
                client_id,
                assigned_sn,
                msn,
                sequence_state,
                acc_ops,
                acc_nacks,
                acc_state,
              )
            False -> {
              let sequenced_op =
                build_sequenced_op(op, Some(client_id), assigned_sn, msn)
              let op_history =
                session_logic.add_to_history(
                  sequenced_op,
                  acc_state.op_history,
                  max_history_size,
                )
              let _ =
                levee_storage.ets_store_delta(
                  acc_state.tables,
                  acc_state.tenant_id,
                  acc_state.document_id,
                  sequenced_op_to_delta(sequenced_op),
                )
              #(
                [sequenced_op, ..acc_ops],
                acc_nacks,
                State(
                  ..acc_state,
                  sequence_state: sequence_state,
                  op_history: op_history,
                ),
              )
            }
          }
        sequencing.SequenceError(reason) -> {
          let rejected = nack_from_sequence_error(reason)
          #(acc_ops, [rejected, ..acc_nacks], acc_state)
        }
      }
    })
  case nacks {
    [] -> #(Ok(list.reverse(sequenced)), final_state)
    _ -> #(Error(SequenceRejected(list.reverse(nacks))), final_state)
  }
}

fn process_summarize_op(
  op: Operation,
  client_id: String,
  assigned_sn: Int,
  msn: Int,
  sequence_state: sequencing.SequenceState,
  acc_ops: List(SequencedOp),
  acc_nacks: List(nack.Nack),
  state: State,
) -> #(List(SequencedOp), List(nack.Nack), State) {
  case decode.run(op.contents, decode.dict(decode.string, decode.dynamic)) {
    Error(_) -> #(
      acc_ops,
      [
        nack.bad_request("Invalid summarize op: contents must be a map", None),
        ..acc_nacks
      ],
      state,
    )
    Ok(contents) ->
      case session_logic.validate_summarize_contents(contents) {
        Error(reason) -> #(
          acc_ops,
          [
            nack.bad_request("Invalid summarize op: " <> reason, None),
            ..acc_nacks
          ],
          state,
        )
        Ok(_) -> {
          let handle = decode_string_field(contents, "handle", "")
          let head = decode_string_field(contents, "head", "")
          let parents = decode_string_list_field(contents, "parents")
          let message = decode_optional_string_field(contents, "message")
          let author =
            dynamic.properties([
              #(dynamic.string("name"), dynamic.string("Levee")),
              #(dynamic.string("email"), dynamic.string("server@levee.local")),
            ])
          let commit_result =
            levee_storage.ets_create_commit(
              state.tables,
              state.tenant_id,
              head,
              parents,
              message,
              author,
              author,
            )
          case commit_result {
            Error(_storage_error) -> #(
              acc_ops,
              [nack.bad_request("Could not store summary", None), ..acc_nacks],
              state,
            )
            Ok(commit) -> {
              let ref_path = "refs/heads/" <> state.document_id
              let _ = case
                levee_storage.ets_update_ref(
                  state.tables,
                  state.tenant_id,
                  ref_path,
                  commit.sha,
                )
              {
                Ok(_) -> Ok(Nil)
                Error(types.NotFound) ->
                  levee_storage.ets_create_ref(
                    state.tables,
                    state.tenant_id,
                    ref_path,
                    commit.sha,
                  )
                  |> result_nil
                Error(e) -> Error(e)
              }
              let summary =
                types.Summary(
                  handle: handle,
                  tenant_id: state.tenant_id,
                  document_id: state.document_id,
                  sequence_number: assigned_sn,
                  tree_sha: head,
                  commit_sha: Some(commit.sha),
                  parent_handle: first_option(parents),
                  message: message,
                  created_at: dynamic.int(time.now_millis()),
                )
              let _ =
                levee_storage.ets_store_summary(
                  state.tables,
                  state.tenant_id,
                  state.document_id,
                  summary,
                )
              let sequenced_summarize =
                build_sequenced_op(op, Some(client_id), assigned_sn, msn)
              let summary_ack =
                SequencedOp(
                  client_id: None,
                  sequence_number: assigned_sn + 1,
                  minimum_sequence_number: msn,
                  client_sequence_number: -1,
                  reference_sequence_number: assigned_sn,
                  message_type: "summaryAck",
                  contents: dynamic.properties([
                    #(dynamic.string("handle"), dynamic.string(handle)),
                    #(
                      dynamic.string("summaryProposal"),
                      dynamic.properties([
                        #(
                          dynamic.string("summarySequenceNumber"),
                          dynamic.int(assigned_sn),
                        ),
                      ]),
                    ),
                  ]),
                  metadata: None,
                  timestamp: time.now_millis(),
                  data: None,
                )
              let op_history =
                session_logic.add_to_history(
                  summary_ack,
                  session_logic.add_to_history(
                    sequenced_summarize,
                    state.op_history,
                    max_history_size,
                  ),
                  max_history_size,
                )
              let _ =
                levee_storage.ets_store_delta(
                  state.tables,
                  state.tenant_id,
                  state.document_id,
                  sequenced_op_to_delta(sequenced_summarize),
                )
              let _ =
                levee_storage.ets_store_delta(
                  state.tables,
                  state.tenant_id,
                  state.document_id,
                  sequenced_op_to_delta(summary_ack),
                )
              #(
                [summary_ack, sequenced_summarize, ..acc_ops],
                acc_nacks,
                State(
                  ..state,
                  sequence_state: sequence_state,
                  op_history: op_history,
                  latest_summary: Some(SummaryContext(
                    handle: handle,
                    sequence_number: assigned_sn,
                  )),
                ),
              )
            }
          }
        }
      }
  }
}

fn first_option(list: List(a)) -> Option(a) {
  case list {
    [first, ..] -> Some(first)
    [] -> None
  }
}

fn result_nil(result: Result(a, e)) -> Result(Nil, e) {
  case result {
    Ok(_) -> Ok(Nil)
    Error(e) -> Error(e)
  }
}

fn build_sequenced_op(
  op: Operation,
  client_id: Option(String),
  sn: Int,
  msn: Int,
) -> SequencedOp {
  SequencedOp(
    client_id: client_id,
    sequence_number: sn,
    minimum_sequence_number: msn,
    client_sequence_number: op.client_sequence_number,
    reference_sequence_number: op.reference_sequence_number,
    message_type: op.message_type,
    contents: op.contents,
    metadata: op.metadata,
    timestamp: time.now_millis(),
    data: None,
  )
}

fn generate_system_message(
  message_type: String,
  client_id: String,
  content: Dynamic,
  sequence_state: sequencing.SequenceState,
  history: List(SequencedOp),
  state: State,
) -> #(SequencedOp, sequencing.SequenceState, List(SequencedOp)) {
  let current_sn = sequencing.current_sn(sequence_state)
  let new_sn = current_sn + 1
  let msn = sequencing.current_msn(sequence_state)
  let message =
    SequencedOp(
      client_id: None,
      sequence_number: new_sn,
      minimum_sequence_number: msn,
      client_sequence_number: -1,
      reference_sequence_number: current_sn,
      message_type: message_type,
      contents: content,
      metadata: None,
      timestamp: time.now_millis(),
      data: Some(message_type <> ":" <> client_id),
    )
  let updated_sequence = sequencing.from_checkpoint(new_sn, msn)
  let final_sequence =
    sequencing.connected_clients(sequence_state)
    |> list.fold(updated_sequence, fn(acc, cid) {
      sequencing.client_join(acc, cid, new_sn)
    })
  let history = session_logic.add_to_history(message, history, max_history_size)
  let _ =
    levee_storage.ets_store_delta(
      state.tables,
      state.tenant_id,
      state.document_id,
      sequenced_op_to_delta(message),
    )
  #(message, final_sequence, history)
}

fn broadcast_ops(
  document_id: String,
  ops: List(SequencedOp),
  clients: Dict(String, ClientInfo),
) -> Nil {
  list.each(dict.values(clients), fn(client) {
    case client.subscriber {
      Some(subscriber) ->
        process.send(subscriber, OpsBroadcast(document_id, ops))
      None -> Nil
    }
  })
}

fn broadcast_signal(
  sender_client_id: String,
  signal: Signal,
  clients: Dict(String, ClientInfo),
) -> Nil {
  let all_client_ids = dict.keys(clients)
  let recipients =
    session_logic.determine_signal_recipients(
      sender_client_id,
      signal.targeted_clients,
      signal.ignored_clients,
      signal.target_client_id,
      all_client_ids,
    )
  let message =
    SignalMessage(client_id: sender_client_id, content: signal.content)
  list.each(recipients, fn(client_id) {
    case dict.get(clients, client_id) {
      Ok(ClientInfo(subscriber: Some(subscriber), ..)) ->
        process.send(subscriber, SignalBroadcast(message))
      _ -> Nil
    }
  })
}

fn sequenced_op_to_delta(op: SequencedOp) -> types.Delta {
  types.Delta(
    sequence_number: op.sequence_number,
    client_id: op.client_id,
    client_sequence_number: op.client_sequence_number,
    reference_sequence_number: op.reference_sequence_number,
    minimum_sequence_number: op.minimum_sequence_number,
    op_type: op.message_type,
    contents: op.contents,
    metadata: option_to_dynamic(op.metadata),
    timestamp: op.timestamp,
  )
}

fn delta_to_sequenced_op(delta: types.Delta) -> SequencedOp {
  SequencedOp(
    client_id: delta.client_id,
    sequence_number: delta.sequence_number,
    minimum_sequence_number: delta.minimum_sequence_number,
    client_sequence_number: delta.client_sequence_number,
    reference_sequence_number: delta.reference_sequence_number,
    message_type: delta.op_type,
    contents: delta.contents,
    metadata: Some(delta.metadata),
    timestamp: delta.timestamp,
    data: None,
  )
}

fn load_latest_summary(
  tables: levee_storage.Tables,
  tenant_id: String,
  document_id: String,
) -> Option(SummaryContext) {
  case levee_storage.ets_get_latest_summary(tables, tenant_id, document_id) {
    Ok(summary) ->
      Some(SummaryContext(
        handle: summary.handle,
        sequence_number: summary.sequence_number,
      ))
    Error(_) -> None
  }
}

fn nack_from_sequence_error(error: sequencing.SequenceError) -> nack.Nack {
  case error {
    sequencing.InvalidCsn(expected, received) ->
      nack.invalid_csn(expected, received, None)
    sequencing.InvalidRsn(current_sn, received_rsn) ->
      nack.invalid_rsn(current_sn, received_rsn, None)
    sequencing.UnknownClient(client_id) -> nack.unknown_client(client_id)
  }
}

fn option_to_dynamic(value: Option(Dynamic)) -> Dynamic {
  case value {
    Some(v) -> v
    None -> dynamic.nil()
  }
}

fn decode_string_field(
  contents: Dict(String, Dynamic),
  field: String,
  default: String,
) -> String {
  case dict.get(contents, field) {
    Ok(value) -> decode.run(value, decode.string) |> result_string(default)
    Error(_) -> default
  }
}

fn decode_optional_string_field(
  contents: Dict(String, Dynamic),
  field: String,
) -> Option(String) {
  case dict.get(contents, field) {
    Ok(value) ->
      case decode.run(value, decode.string) {
        Ok(string) -> Some(string)
        Error(_) -> None
      }
    Error(_) -> None
  }
}

fn decode_string_list_field(
  contents: Dict(String, Dynamic),
  field: String,
) -> List(String) {
  case dict.get(contents, field) {
    Ok(value) ->
      case decode.run(value, decode.list(decode.string)) {
        Ok(strings) -> strings
        Error(_) -> []
      }
    Error(_) -> []
  }
}

fn result_string(result: Result(String, a), default: String) -> String {
  case result {
    Ok(value) -> value
    Error(_) -> default
  }
}
