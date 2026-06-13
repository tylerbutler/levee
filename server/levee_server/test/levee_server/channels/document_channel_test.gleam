import beryl
import beryl/channel
import beryl/socket
import beryl/wire
import gleam/dynamic
import gleam/dynamic/decode
import gleam/json
import gleeunit/should
import levee_server/auth
import levee_server/channels/document_channel
import levee_server/storage
import levee_storage

const tenant = "phase5-tenant"

const document = "phase5-doc"

const user = "phase5-user"

const secret = "phase5-secret"

pub fn join_accepts_document_topic_and_sets_assigns_test() {
  let assert Ok(channels) = beryl.start(beryl.config(wire.phoenix_codec()))
  let handler = document_channel.new(channels)
  let socket = test_socket()

  let result =
    handler.join(
      "document:" <> tenant <> ":" <> document,
      dynamic.properties([]),
      socket,
    )

  case result {
    channel.JoinOk(reply: _, socket:) -> {
      let assigns = socket.get_assigns(socket)
      assigns.tenant_id
      |> should.equal(tenant)
      assigns.document_id
      |> should.equal(document)
      assigns.connected
      |> should.equal(False)
    }
    channel.JoinError(reason:) ->
      json.to_string(reason)
      |> should.equal("join should have succeeded")
  }
}

pub fn join_rejects_invalid_document_topic_test() {
  let assert Ok(channels) = beryl.start(beryl.config(wire.phoenix_codec()))
  let handler = document_channel.new(channels)

  let result =
    handler.join("document:only-tenant", dynamic.properties([]), test_socket())

  case result {
    channel.JoinError(reason:) ->
      json.to_string(reason)
      |> should.equal("{\"reason\":\"invalid_topic\"}")
    channel.JoinOk(..) ->
      "joined"
      |> should.equal("should reject")
  }
}

pub fn parse_topic_preserves_colons_in_document_id_test() {
  document_channel.parse_topic("document:tenant-a:folder:doc")
  |> should.equal(Ok(#("tenant-a", "folder:doc")))
}

pub fn connect_document_with_valid_token_pushes_success_test() {
  setup_storage("build/phase5-valid-token-storage")
  auth.put_secret_for_test(tenant, secret)
  let token =
    auth.sign_for_test(
      tenant,
      document,
      user,
      ["doc:read", "doc:write"],
      secret,
      3600,
    )
  let assert Ok(channels) = beryl.start(beryl.config(wire.phoenix_codec()))
  let handler = document_channel.new(channels)
  let assert channel.JoinOk(socket:, ..) =
    handler.join(
      "document:" <> tenant <> ":" <> document,
      dynamic.properties([]),
      test_socket(),
    )

  let result =
    handler.handle_in(
      "connect_document",
      connect_payload(token, "write"),
      socket,
    )

  case result {
    channel.Push(event:, payload:, socket:) -> {
      event
      |> should.equal("connect_document_success")
      let assigns = socket.get_assigns(socket)
      assigns.connected
      |> should.equal(True)
      assigns.client_id
      |> should.not_equal("")
      let _ =
        json.parse(json.to_string(payload), connected_decoder())
        |> should.be_ok
      Nil
    }
    _ ->
      "not push"
      |> should.equal("expected connect_document_success push")
  }
}

pub fn connect_document_with_invalid_token_pushes_error_test() {
  setup_storage("build/phase5-invalid-token-storage")
  auth.put_secret_for_test(tenant, secret)
  let token =
    auth.sign_for_test(
      tenant,
      document,
      user,
      ["doc:read", "doc:write"],
      "wrong-secret",
      3600,
    )
  let assert Ok(channels) = beryl.start(beryl.config(wire.phoenix_codec()))
  let handler = document_channel.new(channels)
  let assert channel.JoinOk(socket:, ..) =
    handler.join(
      "document:" <> tenant <> ":" <> document,
      dynamic.properties([]),
      test_socket(),
    )

  let result =
    handler.handle_in(
      "connect_document",
      connect_payload(token, "write"),
      socket,
    )

  case result {
    channel.Push(event:, payload:, socket:) -> {
      event
      |> should.equal("connect_document_error")
      socket.get_assigns(socket).connected
      |> should.equal(False)
      json.to_string(payload)
      |> should.equal("{\"code\":401,\"message\":\"Invalid token signature\"}")
    }
    _ ->
      "not push"
      |> should.equal("expected connect_document_error push")
  }
}

pub fn connect_document_without_token_pushes_auth_error_test() {
  setup_storage("build/phase5-missing-token-storage")
  auth.put_secret_for_test(tenant, secret)
  let assert Ok(channels) = beryl.start(beryl.config(wire.phoenix_codec()))
  let handler = document_channel.new(channels)
  let assert channel.JoinOk(socket:, ..) =
    handler.join(
      "document:" <> tenant <> ":" <> document,
      dynamic.properties([]),
      test_socket(),
    )

  let result =
    handler.handle_in(
      "connect_document",
      connect_payload_without_token(),
      socket,
    )

  case result {
    channel.Push(event:, payload:, ..) -> {
      event
      |> should.equal("connect_document_error")
      json.to_string(payload)
      |> should.equal(
        "{\"code\":401,\"message\":\"Missing authentication token\"}",
      )
    }
    _ ->
      "not push"
      |> should.equal("expected connect_document_error push")
  }
}

pub fn connect_document_rejects_unknown_mode_before_write_join_test() {
  setup_storage("build/phase5-invalid-mode-storage")
  auth.put_secret_for_test(tenant, secret)
  let token =
    auth.sign_for_test(tenant, document, user, ["doc:read"], secret, 3600)
  let assert Ok(channels) = beryl.start(beryl.config(wire.phoenix_codec()))
  let handler = document_channel.new(channels)
  let assert channel.JoinOk(socket:, ..) =
    handler.join(
      "document:" <> tenant <> ":" <> document,
      dynamic.properties([]),
      test_socket(),
    )

  let result =
    handler.handle_in(
      "connect_document",
      connect_payload(token, "nonsense"),
      socket,
    )

  case result {
    channel.Push(event:, payload:, socket:) -> {
      event
      |> should.equal("connect_document_error")
      socket.get_assigns(socket).connected
      |> should.equal(False)
      json.to_string(payload)
      |> should.equal("{\"code\":400,\"message\":\"Invalid connection mode\"}")
    }
    _ ->
      "not push"
      |> should.equal("expected invalid mode error")
  }
}

pub fn submit_summarize_requires_summary_write_scope_test() {
  setup_storage("build/phase5-summary-scope-storage")
  auth.put_secret_for_test(tenant, secret)
  let token =
    auth.sign_for_test(
      tenant,
      document,
      user,
      ["doc:read", "doc:write"],
      secret,
      3600,
    )
  let assert Ok(channels) = beryl.start(beryl.config(wire.phoenix_codec()))
  let handler = document_channel.new(channels)
  let assert channel.JoinOk(socket:, ..) =
    handler.join(
      "document:" <> tenant <> ":" <> document,
      dynamic.properties([]),
      test_socket(),
    )
  let assert channel.Push(socket: connected_socket, ..) =
    handler.handle_in(
      "connect_document",
      connect_payload(token, "write"),
      socket,
    )
  let client_id = socket.get_assigns(connected_socket).client_id

  let result =
    handler.handle_in(
      "submitOp",
      summarize_payload(client_id),
      connected_socket,
    )

  case result {
    channel.Push(event:, payload:, ..) -> {
      event
      |> should.equal("nack")
      json.to_string(payload)
      |> should.equal(
        "{\"clientId\":\"\",\"nacks\":[{\"operation\":null,\"sequenceNumber\":-1,\"content\":{\"code\":403,\"type\":\"InvalidScopeError\",\"message\":\"Missing summary:write scope\"}}]}",
      )
    }
    _ ->
      "not push"
      |> should.equal("expected summary scope nack")
  }
}

pub fn ops_broadcast_payload_uses_phoenix_event_shape_test() {
  let op =
    document_channel.test_sequenced_op(
      client_id: "client-1",
      sequence_number: 3,
      client_sequence_number: 2,
      reference_sequence_number: 1,
      message_type: "op",
      contents: dynamic.properties([#(dynamic.string("value"), dynamic.int(1))]),
    )

  document_channel.broadcast_payload(
    document_channel.OpsForTest(document, [op]),
  )
  |> json.to_string
  |> should.equal(
    "{\"documentId\":\"phase5-doc\",\"op\":[{\"clientId\":\"client-1\",\"sequenceNumber\":3,\"minimumSequenceNumber\":0,\"clientSequenceNumber\":2,\"referenceSequenceNumber\":1,\"type\":\"op\",\"contents\":{\"value\":1},\"metadata\":null,\"timestamp\":123,\"data\":null}]}",
  )
}

pub fn legacy_signal_strings_decode_as_signal_content_test() {
  let payload =
    dynamic.properties([
      #(dynamic.string("clientId"), dynamic.string("client-1")),
      #(
        dynamic.string("contentBatches"),
        dynamic.list([dynamic.list([dynamic.string("{\"type\":\"presence\"}")])]),
      ),
    ])

  document_channel.decode_signals_for_test(payload)
  |> should.be_ok
}

pub fn flat_signal_batches_decode_as_single_batch_test() {
  let payload =
    dynamic.properties([
      #(dynamic.string("clientId"), dynamic.string("client-1")),
      #(
        dynamic.string("contentBatches"),
        dynamic.list([
          dynamic.properties([
            #(dynamic.string("content"), dynamic.string("flat-signal")),
          ]),
        ]),
      ),
    ])

  document_channel.decode_signals_for_test(payload)
  |> should.be_ok
}

pub fn invalid_top_level_signal_string_is_dropped_for_legacy_parity_test() {
  let payload =
    dynamic.properties([
      #(dynamic.string("clientId"), dynamic.string("client-1")),
      #(
        dynamic.string("contentBatches"),
        dynamic.list([dynamic.string("not json")]),
      ),
    ])

  document_channel.decode_signals_for_test(payload)
  |> should.equal(Ok(0))
}

pub type ConnectedPayload {
  ConnectedPayload(client_id: String, mode: String)
}

fn connected_decoder() {
  use client_id <- decode.field("clientId", decode.string)
  use mode <- decode.field("mode", decode.string)
  decode.success(ConnectedPayload(client_id:, mode:))
}

fn connect_payload(token: String, mode: String) {
  dynamic.properties([
    #(dynamic.string("tenantId"), dynamic.string(tenant)),
    #(dynamic.string("id"), dynamic.string(document)),
    #(dynamic.string("token"), dynamic.string(token)),
    #(
      dynamic.string("client"),
      dynamic.properties([#(dynamic.string("mode"), dynamic.string("test"))]),
    ),
    #(dynamic.string("mode"), dynamic.string(mode)),
    #(dynamic.string("versions"), dynamic.list([dynamic.string("^0.1.0")])),
  ])
}

fn connect_payload_without_token() {
  dynamic.properties([
    #(dynamic.string("tenantId"), dynamic.string(tenant)),
    #(dynamic.string("id"), dynamic.string(document)),
    #(
      dynamic.string("client"),
      dynamic.properties([#(dynamic.string("mode"), dynamic.string("test"))]),
    ),
    #(dynamic.string("mode"), dynamic.string("write")),
    #(dynamic.string("versions"), dynamic.list([dynamic.string("^0.1.0")])),
  ])
}

fn summarize_payload(client_id: String) {
  dynamic.properties([
    #(dynamic.string("clientId"), dynamic.string(client_id)),
    #(
      dynamic.string("messageBatches"),
      dynamic.list([
        dynamic.list([
          dynamic.properties([
            #(dynamic.string("clientSequenceNumber"), dynamic.int(1)),
            #(dynamic.string("referenceSequenceNumber"), dynamic.int(0)),
            #(dynamic.string("type"), dynamic.string("summarize")),
            #(dynamic.string("contents"), dynamic.properties([])),
          ]),
        ]),
      ]),
    ),
  ])
}

fn setup_storage(path: String) {
  document_channel.clear_supervisor_for_test()
  storage.ensure_dir_for_test(path)
  let tables = levee_storage.ets_init(path)
  storage.put_tables_for_test(tables)
  let _ = levee_storage.ets_create_document(tables, tenant, document, 0)
  Nil
}

fn test_socket() {
  socket.new(
    "socket-test",
    document_channel.initial_assigns_for_test(),
    socket.Transport(
      send_text: fn(_) { Ok(Nil) },
      send_binary: fn(_) { Ok(Nil) },
      close: fn() { Ok(Nil) },
    ),
  )
}
