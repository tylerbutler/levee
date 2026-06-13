import beryl.{type Channels}
import beryl/channel.{type Channel, type HandleResult, type JoinResult}
import beryl/socket.{type Socket}
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import levee_documents/session
import levee_documents/supervisor
import levee_protocol/nack
import levee_protocol/signals
import levee_server/auth
import levee_server/storage

const max_batch_size = 100

pub type Assigns {
  Assigns(
    topic_name: String,
    tenant_id: String,
    document_id: String,
    client_id: String,
    mode: String,
    connected: Bool,
    session_actor: Option(Subject(session.Message)),
    subscriber: Option(Subject(session.Broadcast)),
    subscriber_pid: Option(Pid),
    claims: Option(auth.Claims),
  )
}

type ConnectPayload {
  ConnectPayload(
    tenant_id: String,
    document_id: String,
    token: Option(String),
    client: Dynamic,
    mode: String,
    supported_features: Dict(String, Bool),
    versions: List(String),
    last_seen_sequence_number: Option(Int),
  )
}

type SubmitOpPayload {
  SubmitOpPayload(
    client_id: String,
    message_batches: List(List(session.Operation)),
  )
}

type SubmitSignalPayload {
  SubmitSignalPayload(client_id: String, content_batches: List(Dynamic))
}

type NoopPayload {
  NoopPayload(client_id: String, reference_sequence_number: Int)
}

type RequestOpsPayload {
  RequestOpsPayload(from: Int)
}

type InfoMessage {
  PushInfo(event: String, payload: json.Json)
}

pub type BroadcastForTest {
  OpsForTest(document_id: String, ops: List(session.SequencedOp))
  SignalForTest(client_id: String, content: Dynamic)
}

@external(erlang, "levee_server_ffi", "get_document_supervisor")
fn ffi_get_document_supervisor() -> Result(supervisor.Supervisor, Nil)

@external(erlang, "levee_server_ffi", "put_document_supervisor")
fn ffi_put_document_supervisor(supervisor: supervisor.Supervisor) -> Nil

@external(erlang, "levee_server_ffi", "clear_document_supervisor")
pub fn clear_supervisor_for_test() -> Nil

@external(erlang, "gleam_stdlib", "identity")
fn unsafe_dynamic_to_info(message: Dynamic) -> InfoMessage

pub fn new(channels: Channels) -> Channel(Assigns) {
  channel.new(join)
  |> channel.with_handle_in(fn(event, payload, socket) {
    handle_in(channels, event, payload, socket)
  })
  |> channel.with_handle_info(handle_info)
  |> channel.with_terminate(terminate)
}

pub fn initial_assigns_for_test() -> Assigns {
  Assigns(
    topic_name: "",
    tenant_id: "",
    document_id: "",
    client_id: "",
    mode: "",
    connected: False,
    session_actor: None,
    subscriber: None,
    subscriber_pid: None,
    claims: None,
  )
}

pub fn decode_signals_for_test(payload: Dynamic) -> Result(Int, Nil) {
  case decode.run(payload, submit_signal_decoder()) {
    Ok(input) ->
      Ok(input.content_batches |> normalize_signal_batches |> list.length)
    Error(_) -> Error(Nil)
  }
}

pub fn parse_topic(topic_name: String) -> Result(#(String, String), Nil) {
  case topic_name {
    "document:" <> rest ->
      case string.split(rest, ":") {
        [tenant_id, first_doc_part, ..rest_doc_parts] ->
          Ok(#(tenant_id, string.join([first_doc_part, ..rest_doc_parts], ":")))
        _ -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

fn join(
  topic_name: String,
  _payload: Dynamic,
  socket: Socket(Assigns),
) -> JoinResult(Assigns) {
  case parse_topic(topic_name) {
    Ok(#(tenant_id, document_id)) -> {
      let assigns =
        Assigns(
          topic_name: topic_name,
          tenant_id: tenant_id,
          document_id: document_id,
          client_id: "",
          mode: "",
          connected: False,
          session_actor: None,
          subscriber: None,
          subscriber_pid: None,
          claims: None,
        )
      channel.JoinOk(reply: None, socket: socket.set_assigns(socket, assigns))
    }
    Error(Nil) -> channel.JoinError(reason: invalid_topic_json())
  }
}

fn handle_in(
  channels: Channels,
  event: String,
  payload: Dynamic,
  socket: Socket(Assigns),
) -> HandleResult(Assigns) {
  case event {
    "connect_document" -> connect_document(channels, payload, socket)
    "submitOp" -> submit_op(payload, socket)
    "submitSignal" -> submit_signal(payload, socket)
    "noop" -> noop(payload, socket)
    "requestOps" -> request_ops(payload, socket)
    _ -> channel.NoReply(socket)
  }
}

fn connect_document(
  channels: Channels,
  payload: Dynamic,
  socket: Socket(Assigns),
) -> HandleResult(Assigns) {
  let assigns = socket.get_assigns(socket)
  case decode.run(payload, connect_decoder()) {
    Error(_) ->
      connect_error(
        socket,
        400,
        "Missing required fields: tenantId, id, client, mode",
      )
    Ok(connect) ->
      case
        connect.tenant_id == assigns.tenant_id
        && connect.document_id == assigns.document_id
      {
        False ->
          connect_error(socket, 400, "Tenant/document ID mismatch with topic")
        True -> authenticate_and_join(channels, connect, socket)
      }
  }
}

fn authenticate_and_join(
  channels: Channels,
  connect: ConnectPayload,
  socket: Socket(Assigns),
) -> HandleResult(Assigns) {
  let assigns = socket.get_assigns(socket)
  case connect.token {
    None -> connect_auth_error(socket, auth.MissingToken)
    Some(token) ->
      case auth.tenant_secrets(assigns.tenant_id) {
        Error(error) -> connect_auth_error(socket, error)
        Ok(secrets) ->
          case auth.verify_token(token, assigns.tenant_id, secrets) {
            Error(error) -> connect_auth_error(socket, error)
            Ok(claims) ->
              case auth.require_scopes(claims, [auth.scope_doc_read]) {
                Error(error) -> connect_auth_error(socket, error)
                Ok(Nil) ->
                  validate_mode_and_join(channels, connect, claims, socket)
              }
          }
      }
  }
}

fn validate_mode_and_join(
  channels: Channels,
  connect: ConnectPayload,
  claims: auth.Claims,
  socket: Socket(Assigns),
) -> HandleResult(Assigns) {
  let assigns = socket.get_assigns(socket)
  case assigns.connected {
    True -> connect_error(socket, 400, "Client already connected")
    False -> validate_document_and_mode(channels, connect, claims, socket)
  }
}

fn validate_document_and_mode(
  channels: Channels,
  connect: ConnectPayload,
  claims: auth.Claims,
  socket: Socket(Assigns),
) -> HandleResult(Assigns) {
  let assigns = socket.get_assigns(socket)
  case claims.document_id == assigns.document_id {
    False ->
      connect_auth_error(
        socket,
        auth.DocumentMismatch(claims.document_id, assigns.document_id),
      )
    True ->
      case connect.mode {
        "write" ->
          case auth.require_scopes(claims, [auth.scope_doc_write]) {
            Error(_) ->
              connect_error(socket, 403, "Write mode requires doc:write scope")
            Ok(Nil) -> join_session(channels, connect, claims, socket)
          }
        "read" -> join_session(channels, connect, claims, socket)
        _ -> connect_error(socket, 400, "Invalid connection mode")
      }
  }
}

fn join_session(
  channels: Channels,
  connect: ConnectPayload,
  claims: auth.Claims,
  socket: Socket(Assigns),
) -> HandleResult(Assigns) {
  let assigns = socket.get_assigns(socket)
  case get_or_start_supervisor() {
    Error(Nil) -> connect_error(socket, 500, "Failed to start document session")
    Ok(doc_supervisor) ->
      case
        supervisor.get_or_create_session(
          doc_supervisor,
          assigns.tenant_id,
          assigns.document_id,
        )
      {
        Error(_) ->
          connect_error(socket, 500, "Failed to start document session")
        Ok(session_actor) -> {
          let mode = mode_from_string(connect.mode)
          let connect_msg =
            session.Connect(
              client: connect.client,
              mode: mode,
              supported_features: connect.supported_features,
              versions: connect.versions,
            )
          case session.client_join(session_actor, connect_msg) {
            Error(error) ->
              connect_error(socket, 400, session_error_message(error))
            Ok(connected) -> {
              let #(subscriber, subscriber_pid) =
                start_forwarder(channels, socket.id(socket), assigns.topic_name)
              session.subscribe(session_actor, connected.client_id, subscriber)
              let _ = case connect.last_seen_sequence_number {
                Some(since_sn) ->
                  case session.get_ops_since(session_actor, since_sn) {
                    Ok([_, ..] as ops) ->
                      send_pushes(
                        channels,
                        socket.id(socket),
                        assigns.topic_name,
                        ops_pushes(assigns.document_id, ops),
                      )
                    _ -> Nil
                  }
                None -> Nil
              }
              let new_assigns =
                Assigns(
                  ..assigns,
                  client_id: connected.client_id,
                  mode: connect.mode,
                  connected: True,
                  session_actor: Some(session_actor),
                  subscriber: Some(subscriber),
                  subscriber_pid: Some(subscriber_pid),
                  claims: Some(claims),
                )
              channel.Push(
                event: "connect_document_success",
                payload: connected_json(connected, claims),
                socket: socket.set_assigns(socket, new_assigns),
              )
            }
          }
        }
      }
  }
}

fn submit_op(payload: Dynamic, socket: Socket(Assigns)) -> HandleResult(Assigns) {
  let assigns = socket.get_assigns(socket)
  case decode.run(payload, submit_op_decoder()) {
    Error(_) ->
      push_nack(
        socket,
        400,
        "BadRequestError",
        "Malformed submitOp: missing clientId or messageBatches",
      )
    Ok(input) ->
      case assigns.connected, assigns.session_actor {
        False, _ ->
          push_nack(socket, 400, "BadRequestError", "Client not connected")
        _, None ->
          push_nack(socket, 400, "BadRequestError", "Client not connected")
        True, Some(session_actor) ->
          case input.client_id == assigns.client_id {
            False ->
              push_nack(
                socket,
                400,
                "BadRequestError",
                "Client ID mismatch: expected "
                  <> assigns.client_id
                  <> ", got "
                  <> input.client_id,
              )
            True ->
              case assigns.mode == "read" {
                True ->
                  push_nack(
                    socket,
                    403,
                    "InvalidScopeError",
                    "Read-only clients cannot submit operations",
                  )
                False ->
                  case claims_have_scope(assigns.claims, auth.scope_doc_write) {
                    False ->
                      push_nack(
                        socket,
                        403,
                        "InvalidScopeError",
                        "Missing doc:write scope",
                      )
                    True -> submit_op_to_session(session_actor, input, socket)
                  }
              }
          }
      }
  }
}

fn submit_op_to_session(
  session_actor: Subject(session.Message),
  input: SubmitOpPayload,
  socket: Socket(Assigns),
) -> HandleResult(Assigns) {
  let assigns = socket.get_assigns(socket)
  let ops = list.flatten(input.message_batches)
  let count = list.length(ops)
  case count > max_batch_size {
    True ->
      push_nack(
        socket,
        400,
        "BadRequestError",
        "Batch size "
          <> int.to_string(count)
          <> " exceeds maximum "
          <> int.to_string(max_batch_size),
      )
    False -> {
      let has_summarize_op =
        list.any(ops, fn(op) { op.message_type == "summarize" })
      case
        has_summarize_op
        && !claims_have_scope(assigns.claims, auth.scope_summary_write)
      {
        True ->
          push_nack(
            socket,
            403,
            "InvalidScopeError",
            "Missing summary:write scope",
          )
        False -> submit_validated_ops(session_actor, input, ops, socket)
      }
    }
  }
}

fn submit_validated_ops(
  session_actor: Subject(session.Message),
  input: SubmitOpPayload,
  ops: List(session.Operation),
  socket: Socket(Assigns),
) -> HandleResult(Assigns) {
  case session.submit_ops(session_actor, input.client_id, ops) {
    Ok(_) -> channel.NoReply(socket)
    Error(session.SequenceRejected(nacks)) ->
      channel.Push(event: "nack", payload: nacks_json(nacks), socket:)
    Error(session.ReadOnlyClient) ->
      push_nack(
        socket,
        403,
        "InvalidScopeError",
        "Read-only clients cannot submit operations",
      )
    Error(session.UnknownClient(_)) ->
      push_nack(socket, 400, "BadRequestError", "Client not connected")
    Error(session.StorageFailed(_)) ->
      push_nack(socket, 500, "ServerError", "Failed to store operation")
  }
}

fn submit_signal(
  payload: Dynamic,
  socket: Socket(Assigns),
) -> HandleResult(Assigns) {
  let assigns = socket.get_assigns(socket)
  case decode.run(payload, submit_signal_decoder()) {
    Error(_) -> channel.NoReply(socket)
    Ok(input) ->
      case
        assigns.connected,
        assigns.session_actor,
        input.client_id == assigns.client_id
      {
        True, Some(session_actor), True -> {
          session.submit_signals(
            session_actor,
            input.client_id,
            normalize_signal_batches(input.content_batches),
          )
          channel.NoReply(socket)
        }
        _, _, _ -> channel.NoReply(socket)
      }
  }
}

fn noop(payload: Dynamic, socket: Socket(Assigns)) -> HandleResult(Assigns) {
  let assigns = socket.get_assigns(socket)
  case decode.run(payload, noop_decoder()) {
    Ok(input) ->
      case
        assigns.connected,
        assigns.session_actor,
        input.client_id == assigns.client_id
      {
        True, Some(session_actor), True -> {
          session.update_client_rsn(
            session_actor,
            input.client_id,
            input.reference_sequence_number,
          )
          channel.NoReply(socket)
        }
        _, _, _ -> channel.NoReply(socket)
      }
    Error(_) -> channel.NoReply(socket)
  }
}

fn request_ops(
  payload: Dynamic,
  socket: Socket(Assigns),
) -> HandleResult(Assigns) {
  let assigns = socket.get_assigns(socket)
  case decode.run(payload, request_ops_decoder()) {
    Ok(input) ->
      case assigns.connected, assigns.session_actor {
        True, Some(session_actor) ->
          case session.get_ops_since(session_actor, input.from) {
            Ok([_, ..] as ops) ->
              channel.Push(
                event: "op",
                payload: op_payload(assigns.document_id, ops),
                socket:,
              )
            _ -> channel.NoReply(socket)
          }
        _, _ -> channel.NoReply(socket)
      }
    Error(_) -> channel.NoReply(socket)
  }
}

fn handle_info(
  message: Dynamic,
  socket: Socket(Assigns),
) -> HandleResult(Assigns) {
  let info = unsafe_dynamic_to_info(message)
  case info {
    PushInfo(event, payload) ->
      channel.Push(event: event, payload: payload, socket:)
  }
}

fn terminate(_reason: channel.StopReason, socket: Socket(Assigns)) -> Nil {
  let assigns = socket.get_assigns(socket)
  case assigns.session_actor, assigns.connected, assigns.client_id {
    Some(session_actor), True, client_id -> {
      session.unsubscribe(session_actor, client_id)
      session.client_leave(session_actor, client_id)
    }
    _, _, _ -> Nil
  }
  case assigns.subscriber_pid {
    Some(pid) -> process.send_exit(pid)
    None -> Nil
  }
}

fn start_forwarder(
  channels: Channels,
  socket_id: String,
  topic_name: String,
) -> #(Subject(session.Broadcast), Pid) {
  let parent = process.new_subject()
  let pid =
    process.spawn(fn() {
      let subject = process.new_subject()
      process.send(parent, subject)
      forward_loop(subject, channels, socket_id, topic_name)
    })
  let subject = process.receive_forever(parent)
  #(subject, pid)
}

fn forward_loop(
  subject: Subject(session.Broadcast),
  channels: Channels,
  socket_id: String,
  topic_name: String,
) -> Nil {
  let broadcast = process.receive_forever(subject)
  let pushes = broadcast_to_pushes(broadcast)
  send_pushes(channels, socket_id, topic_name, pushes)
  forward_loop(subject, channels, socket_id, topic_name)
}

fn send_pushes(
  channels: Channels,
  socket_id: String,
  topic_name: String,
  pushes: List(#(String, json.Json)),
) -> Nil {
  list.each(pushes, fn(push) {
    let #(event, payload) = push
    beryl.send_info(channels, socket_id, topic_name, PushInfo(event, payload))
  })
}

fn get_or_start_supervisor() -> Result(supervisor.Supervisor, Nil) {
  case ffi_get_document_supervisor() {
    Ok(doc_supervisor) -> Ok(doc_supervisor)
    Error(Nil) ->
      case supervisor.start(storage.get_or_init_tables()) {
        Error(_) -> Error(Nil)
        Ok(doc_supervisor) -> {
          ffi_put_document_supervisor(doc_supervisor)
          Ok(doc_supervisor)
        }
      }
  }
}

pub fn ensure_supervisor_started() -> Result(supervisor.Supervisor, Nil) {
  get_or_start_supervisor()
}

fn mode_from_string(mode: String) -> session.Mode {
  case mode {
    "read" -> session.Read
    _ -> session.Write
  }
}

fn mode_to_string(mode: session.Mode) -> String {
  case mode {
    session.Read -> "read"
    session.Write -> "write"
  }
}

fn connect_decoder() -> decode.Decoder(ConnectPayload) {
  use tenant_id <- decode.field("tenantId", decode.string)
  use document_id <- decode.field("id", decode.string)
  use token <- decode.optional_field("token", None, optional_string_decoder())
  use client <- decode.field("client", decode.dynamic)
  use mode <- decode.field("mode", decode.string)
  use supported_features <- decode.optional_field(
    "supportedFeatures",
    dict.new(),
    decode.dict(decode.string, decode.bool),
  )
  use versions <- decode.optional_field(
    "versions",
    [],
    decode.list(decode.string),
  )
  use last_seen_sequence_number <- decode.optional_field(
    "lastSeenSequenceNumber",
    None,
    optional_int_decoder(),
  )
  decode.success(ConnectPayload(
    tenant_id:,
    document_id:,
    token:,
    client:,
    mode:,
    supported_features:,
    versions:,
    last_seen_sequence_number:,
  ))
}

fn submit_op_decoder() -> decode.Decoder(SubmitOpPayload) {
  use client_id <- decode.field("clientId", decode.string)
  use message_batches <- decode.field(
    "messageBatches",
    decode.list(decode.list(operation_decoder())),
  )
  decode.success(SubmitOpPayload(client_id:, message_batches:))
}

fn operation_decoder() -> decode.Decoder(session.Operation) {
  use client_sequence_number <- decode.field("clientSequenceNumber", decode.int)
  use reference_sequence_number <- decode.field(
    "referenceSequenceNumber",
    decode.int,
  )
  use message_type <- decode.field("type", decode.string)
  use contents <- decode.field("contents", decode.dynamic)
  use metadata <- decode.optional_field(
    "metadata",
    None,
    optional_dynamic_decoder(),
  )
  decode.success(session.Operation(
    client_sequence_number:,
    reference_sequence_number:,
    message_type:,
    contents:,
    metadata:,
  ))
}

fn submit_signal_decoder() -> decode.Decoder(SubmitSignalPayload) {
  use client_id <- decode.field("clientId", decode.string)
  use content_batches <- decode.field(
    "contentBatches",
    decode.list(decode.dynamic),
  )
  decode.success(SubmitSignalPayload(client_id:, content_batches:))
}

fn normalize_signal_batches(batches: List(Dynamic)) -> List(session.Signal) {
  batches
  |> list.flat_map(normalize_signal_batch)
}

fn normalize_signal_batch(batch: Dynamic) -> List(session.Signal) {
  case decode.run(batch, decode.list(decode.dynamic)) {
    Ok(items) -> list.flat_map(items, normalize_signal_item)
    Error(_) -> normalize_signal_single_batch(batch)
  }
}

fn normalize_signal_single_batch(value: Dynamic) -> List(session.Signal) {
  case decode.run(value, decode.dict(decode.string, decode.dynamic)) {
    Ok(raw) -> [signals.normalize_signal(raw) |> normalized_signal_to_session]
    Error(_) -> {
      case decode.run(value, decode.string) {
        Ok(text) -> normalize_signal_string_batch(text)
        Error(_) -> []
      }
    }
  }
}

fn normalize_signal_item(value: Dynamic) -> List(session.Signal) {
  case decode.run(value, decode.dict(decode.string, decode.dynamic)) {
    Ok(raw) -> [signals.normalize_signal(raw) |> normalized_signal_to_session]
    Error(_) -> {
      case decode.run(value, decode.string) {
        Ok(text) -> normalize_signal_string_item(text)
        Error(_) -> [fallback_signal(dynamic.nil())]
      }
    }
  }
}

fn normalize_signal_string_batch(text: String) -> List(session.Signal) {
  case json.parse(text, decode.dynamic) {
    Ok(decoded) -> normalize_signal_single_batch(decoded)
    Error(_) -> []
  }
}

fn normalize_signal_string_item(text: String) -> List(session.Signal) {
  case json.parse(text, decode.dynamic) {
    Ok(decoded) -> normalize_signal_single_batch(decoded)
    Error(_) -> [fallback_signal(dynamic.string(text))]
  }
}

fn normalized_signal_to_session(
  signal: signals.NormalizedSignal,
) -> session.Signal {
  session.Signal(
    content: signal.content,
    targeted_clients: signal.targeted_clients,
    ignored_clients: signal.ignored_clients,
    target_client_id: signal.target_client_id,
  )
}

fn fallback_signal(content: Dynamic) -> session.Signal {
  session.Signal(
    content: content,
    targeted_clients: None,
    ignored_clients: None,
    target_client_id: None,
  )
}

fn noop_decoder() -> decode.Decoder(NoopPayload) {
  use client_id <- decode.field("clientId", decode.string)
  use reference_sequence_number <- decode.field(
    "referenceSequenceNumber",
    decode.int,
  )
  decode.success(NoopPayload(client_id:, reference_sequence_number:))
}

fn request_ops_decoder() -> decode.Decoder(RequestOpsPayload) {
  use from <- decode.field("from", decode.int)
  decode.success(RequestOpsPayload(from:))
}

fn optional_int_decoder() -> decode.Decoder(Option(Int)) {
  decode.optional(decode.int)
}

fn optional_dynamic_decoder() -> decode.Decoder(Option(Dynamic)) {
  decode.optional(decode.dynamic)
}

fn optional_string_decoder() -> decode.Decoder(Option(String)) {
  decode.optional(decode.string)
}

fn connect_auth_error(
  socket: Socket(Assigns),
  error: auth.AuthError,
) -> HandleResult(Assigns) {
  let #(code, message) = case error {
    auth.MissingToken -> #(401, "Missing authentication token")
    auth.InvalidAuthHeader -> #(
      401,
      "Invalid Authorization header format. Expected: Bearer <token>",
    )
    auth.InvalidSignature -> #(401, "Invalid token signature")
    auth.TokenExpired -> #(401, "Token has expired")
    auth.InvalidTokenFormat -> #(401, "Invalid token format")
    auth.UnknownTenant -> #(401, "Unknown tenant")
    auth.MissingTenantId -> #(400, "Missing tenant ID in request")
    auth.TenantMismatch(_, _) -> #(403, "Token not valid for this tenant")
    auth.DocumentMismatch(_, _) -> #(403, "Token not valid for this document")
    auth.MissingScopes(scopes) -> #(
      403,
      "Token missing required scope: " <> string.join(scopes, ", "),
    )
    auth.AuthenticationError -> #(500, "Authentication error")
  }
  connect_error(socket, code, message)
}

fn connect_error(
  socket: Socket(Assigns),
  code: Int,
  message: String,
) -> HandleResult(Assigns) {
  channel.Push(
    event: "connect_document_error",
    payload: json.object([
      #("code", json.int(code)),
      #("message", json.string(message)),
    ]),
    socket:,
  )
}

fn invalid_topic_json() -> json.Json {
  json.object([#("reason", json.string("invalid_topic"))])
}

fn session_error_message(error: session.SessionError) -> String {
  case error {
    session.UnknownClient(_) -> "Client not connected"
    session.ReadOnlyClient -> "Read-only clients cannot submit operations"
    session.SequenceRejected(_) -> "Sequence rejected"
    session.StorageFailed(_) -> "Storage failed"
  }
}

fn claims_have_scope(claims: Option(auth.Claims), scope: String) -> Bool {
  case claims {
    Some(claims) -> list.contains(claims.scopes, scope)
    None -> False
  }
}

fn push_nack(
  socket: Socket(Assigns),
  code: Int,
  error_type: String,
  message: String,
) -> HandleResult(Assigns) {
  channel.Push(
    event: "nack",
    payload: nack_payload(code, error_type, message),
    socket:,
  )
}

fn nack_payload(code: Int, error_type: String, message: String) -> json.Json {
  json.object([
    #("clientId", json.string("")),
    #(
      "nacks",
      json.array([#(code, error_type, message)], fn(item) {
        let #(code, error_type, message) = item
        json.object([
          #("operation", json.null()),
          #("sequenceNumber", json.int(-1)),
          #(
            "content",
            json.object([
              #("code", json.int(code)),
              #("type", json.string(error_type)),
              #("message", json.string(message)),
            ]),
          ),
        ])
      }),
    ),
  ])
}

fn nacks_json(nacks: List(nack.Nack)) -> json.Json {
  json.object([
    #("clientId", json.string("")),
    #("nacks", json.array(nacks, nack_json)),
  ])
}

fn nack_json(message: nack.Nack) -> json.Json {
  json.object([
    #("operation", json.null()),
    #("sequenceNumber", json.int(message.sequence_number)),
    #(
      "content",
      json.object([
        #("code", json.int(message.content.code)),
        #(
          "type",
          json.string(nack.nack_error_type_to_string(message.content.error_type)),
        ),
        #("message", json.string(message.content.message)),
      ]),
    ),
  ])
}

fn connected_json(
  connected: session.Connected,
  claims: auth.Claims,
) -> json.Json {
  json.object([
    #("clientId", json.string(connected.client_id)),
    #("existing", json.bool(connected.existing)),
    #("maxMessageSize", json.int(connected.max_message_size)),
    #("mode", json.string(mode_to_string(connected.mode))),
    #(
      "serviceConfiguration",
      json.object([
        #("blockSize", json.int(connected.service_configuration.block_size)),
        #(
          "maxMessageSize",
          json.int(connected.service_configuration.max_message_size),
        ),
      ]),
    ),
    #(
      "initialClients",
      json.array(connected.initial_clients, initial_client_json),
    ),
    #(
      "initialMessages",
      json.array(connected.initial_messages, sequenced_op_json),
    ),
    #("initialSignals", json.array([], fn(signal) { signal })),
    #(
      "supportedVersions",
      json.array(connected.supported_versions, json.string),
    ),
    #("supportedFeatures", features_json(connected.supported_features)),
    #("version", json.string(connected.version)),
    #(
      "checkpointSequenceNumber",
      json.int(connected.checkpoint_sequence_number),
    ),
    #(
      "summaryContext",
      json.nullable(connected.summary_context, summary_context_json),
    ),
    #("claims", claims_json(claims)),
  ])
}

fn initial_client_json(client: session.InitialClient) -> json.Json {
  json.object([
    #("clientId", json.string(client.client_id)),
    #("client", dynamic_json(client.client)),
    #("mode", json.string(mode_to_string(client.mode))),
  ])
}

fn claims_json(claims: auth.Claims) -> json.Json {
  json.object([
    #("documentId", json.string(claims.document_id)),
    #("scopes", json.array(claims.scopes, json.string)),
    #("tenantId", json.string(claims.tenant_id)),
    #("user", json.object([#("id", json.string(claims.user_id))])),
    #("iat", json.int(claims.iat)),
    #("exp", json.int(claims.exp)),
    #("ver", json.string(claims.ver)),
  ])
}

fn summary_context_json(summary: session.SummaryContext) -> json.Json {
  json.object([
    #("handle", json.string(summary.handle)),
    #("sequenceNumber", json.int(summary.sequence_number)),
  ])
}

fn features_json(features: Dict(String, Bool)) -> json.Json {
  json.object(
    features
    |> dict.to_list
    |> list.map(fn(entry) {
      let #(key, value) = entry
      #(key, json.bool(value))
    }),
  )
}

pub fn broadcast_payload(broadcast: BroadcastForTest) -> json.Json {
  case broadcast {
    OpsForTest(document_id, ops) -> op_payload(document_id, ops)
    SignalForTest(client_id, content) ->
      signal_payload(session.SignalMessage(client_id:, content:))
  }
}

fn broadcast_to_pushes(
  broadcast: session.Broadcast,
) -> List(#(String, json.Json)) {
  case broadcast {
    session.OpsBroadcast(document_id, ops) -> ops_pushes(document_id, ops)
    session.SignalBroadcast(message) -> [#("signal", signal_payload(message))]
  }
}

fn ops_pushes(
  document_id: String,
  ops: List(session.SequencedOp),
) -> List(#(String, json.Json)) {
  let summary_ops =
    list.filter(ops, fn(op) {
      op.message_type == "summaryAck" || op.message_type == "summaryNack"
    })
  let regular_ops =
    list.filter(ops, fn(op) {
      op.message_type != "summaryAck" && op.message_type != "summaryNack"
    })
  let summary_pushes =
    list.map(summary_ops, fn(op) { #(op.message_type, sequenced_op_json(op)) })
  case regular_ops {
    [] -> summary_pushes
    _ ->
      list.append(summary_pushes, [
        #("op", op_payload(document_id, regular_ops)),
      ])
  }
}

fn op_payload(document_id: String, ops: List(session.SequencedOp)) -> json.Json {
  json.object([
    #("documentId", json.string(document_id)),
    #("op", json.array(ops, sequenced_op_json)),
  ])
}

fn sequenced_op_json(op: session.SequencedOp) -> json.Json {
  json.object([
    #("clientId", json.nullable(op.client_id, json.string)),
    #("sequenceNumber", json.int(op.sequence_number)),
    #("minimumSequenceNumber", json.int(op.minimum_sequence_number)),
    #("clientSequenceNumber", json.int(op.client_sequence_number)),
    #("referenceSequenceNumber", json.int(op.reference_sequence_number)),
    #("type", json.string(op.message_type)),
    #("contents", dynamic_json(op.contents)),
    #("metadata", json.nullable(op.metadata, dynamic_json)),
    #("timestamp", json.int(op.timestamp)),
    #("data", json.nullable(op.data, json.string)),
  ])
}

fn signal_payload(message: session.SignalMessage) -> json.Json {
  json.object([
    #("clientId", json.string(message.client_id)),
    #("content", dynamic_json(message.content)),
  ])
}

fn dynamic_json(value: a) -> json.Json {
  storage.dynamic_to_json(value)
  |> storage.json_fragment
}

pub fn test_sequenced_op(
  client_id client_id: String,
  sequence_number sequence_number: Int,
  client_sequence_number client_sequence_number: Int,
  reference_sequence_number reference_sequence_number: Int,
  message_type message_type: String,
  contents contents: Dynamic,
) -> session.SequencedOp {
  session.SequencedOp(
    client_id: Some(client_id),
    sequence_number: sequence_number,
    minimum_sequence_number: 0,
    client_sequence_number: client_sequence_number,
    reference_sequence_number: reference_sequence_number,
    message_type: message_type,
    contents: contents,
    metadata: None,
    timestamp: 123,
    data: None,
  )
}
