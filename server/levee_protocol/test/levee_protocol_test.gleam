import gleam/dict
import gleam/dynamic
import gleam/option
import gleam/string
import levee_protocol
import levee_protocol/jwt
import levee_protocol/nack
import levee_protocol/sequencing
import levee_protocol/session_logic
import levee_protocol/signals
import levee_protocol/types
import startest
import startest/expect

pub fn main() -> Nil {
  startest.run(startest.default_config())
}

// ─────────────────────────────────────────────────────────────────────────────
// Sequencing Tests
// ─────────────────────────────────────────────────────────────────────────────

pub fn new_sequence_state_starts_at_zero_test() {
  let state = levee_protocol.new_sequence_state()
  levee_protocol.current_sn(state) |> expect.to_equal(0)
  levee_protocol.current_msn(state) |> expect.to_equal(0)
  levee_protocol.client_count(state) |> expect.to_equal(0)
}

pub fn client_join_test() {
  let state = levee_protocol.new_sequence_state()
  let state = levee_protocol.client_join(state, "client-1", 0)

  levee_protocol.client_count(state) |> expect.to_equal(1)
  levee_protocol.is_client_connected(state, "client-1") |> expect.to_be_true()
  levee_protocol.is_client_connected(state, "client-2") |> expect.to_be_false()
}

pub fn assign_sequence_number_test() {
  let state = levee_protocol.new_sequence_state()
  let state = levee_protocol.client_join(state, "client-1", 0)

  let assert sequencing.SequenceOk(new_state, assigned_sn, msn) =
    sequencing.assign_sequence_number(state, "client-1", 1, 0)

  assigned_sn |> expect.to_equal(1)
  msn |> expect.to_equal(0)
  levee_protocol.current_sn(new_state) |> expect.to_equal(1)
}

pub fn multiple_ops_increment_sn_test() {
  let state = levee_protocol.new_sequence_state()
  let state = levee_protocol.client_join(state, "client-1", 0)

  let assert sequencing.SequenceOk(state, sn, _) =
    sequencing.assign_sequence_number(state, "client-1", 1, 0)
  sn |> expect.to_equal(1)

  let assert sequencing.SequenceOk(state, sn, _) =
    sequencing.assign_sequence_number(state, "client-1", 2, 1)
  sn |> expect.to_equal(2)

  levee_protocol.current_sn(state) |> expect.to_equal(2)
}

pub fn invalid_csn_rejected_test() {
  let state = levee_protocol.new_sequence_state()
  let state = levee_protocol.client_join(state, "client-1", 0)

  let assert sequencing.SequenceOk(state, _, _) =
    sequencing.assign_sequence_number(state, "client-1", 1, 0)

  case sequencing.assign_sequence_number(state, "client-1", 1, 1) {
    sequencing.SequenceError(sequencing.InvalidCsn(_, _)) -> Nil
    other ->
      panic as { "Expected InvalidCsn error, got: " <> string.inspect(other) }
  }
}

pub fn client_leave_test() {
  let state = levee_protocol.new_sequence_state()
  let state = levee_protocol.client_join(state, "client-1", 0)
  let state = levee_protocol.client_join(state, "client-2", 0)

  levee_protocol.client_count(state) |> expect.to_equal(2)

  let state = levee_protocol.client_leave(state, "client-1")

  levee_protocol.client_count(state) |> expect.to_equal(1)
  levee_protocol.is_client_connected(state, "client-1") |> expect.to_be_false()
  levee_protocol.is_client_connected(state, "client-2") |> expect.to_be_true()
}

pub fn msn_tracks_minimum_rsn_across_clients_test() {
  let state = levee_protocol.new_sequence_state()

  let state = levee_protocol.client_join(state, "client-1", 0)

  let assert sequencing.SequenceOk(state, _, msn) =
    sequencing.assign_sequence_number(state, "client-1", 1, 0)
  msn |> expect.to_equal(0)

  let state = levee_protocol.client_join(state, "client-2", 1)

  let assert sequencing.SequenceOk(state, _, msn) =
    sequencing.assign_sequence_number(state, "client-2", 1, 1)
  msn |> expect.to_equal(0)

  let assert sequencing.SequenceOk(_, _, msn) =
    sequencing.assign_sequence_number(state, "client-1", 2, 2)
  msn |> expect.to_equal(1)
}

// ─────────────────────────────────────────────────────────────────────────────
// JWT Validation Tests
// ─────────────────────────────────────────────────────────────────────────────

fn make_test_claims(
  tenant_id: String,
  document_id: String,
  scopes: List(String),
  exp: Int,
) -> types.TokenClaims {
  types.TokenClaims(
    document_id: document_id,
    scopes: scopes,
    tenant_id: tenant_id,
    user: types.User(id: "test-user", properties: dict.new()),
    issued_at: 1000,
    expiration: exp,
    version: "1.0",
    jti: option.None,
  )
}

/// Helper to assert a Result is Error and the error matches a specific variant
fn assert_error_variant(result: Result(a, e), check: fn(e) -> Nil) -> Nil {
  case result {
    Error(err) -> check(err)
    Ok(_) -> panic as "Expected Error, got Ok"
  }
}

// -- Expiration --

pub fn jwt_validate_expiration_valid_test() {
  let claims = make_test_claims("tenant", "doc", ["doc:read"], 2000)

  jwt.validate_expiration(claims, 1500)
  |> expect.to_be_ok()
}

pub fn jwt_validate_expiration_expired_test() {
  let claims = make_test_claims("tenant", "doc", ["doc:read"], 1000)

  jwt.validate_expiration(claims, 1500)
  |> assert_error_variant(fn(err) {
    let assert jwt.TokenExpired(exp, current) = err
    exp |> expect.to_equal(1000)
    current |> expect.to_equal(1500)
  })
}

// -- Tenant --

pub fn jwt_validate_tenant_match_test() {
  let claims = make_test_claims("my-tenant", "doc", ["doc:read"], 2000)

  jwt.validate_tenant(claims, "my-tenant")
  |> expect.to_be_ok()
}

pub fn jwt_validate_tenant_mismatch_test() {
  let claims = make_test_claims("my-tenant", "doc", ["doc:read"], 2000)

  jwt.validate_tenant(claims, "other-tenant")
  |> assert_error_variant(fn(err) {
    let assert jwt.TenantMismatch(token, request) = err
    token |> expect.to_equal("my-tenant")
    request |> expect.to_equal("other-tenant")
  })
}

// -- Document --

pub fn jwt_validate_document_match_test() {
  let claims = make_test_claims("tenant", "my-doc", ["doc:read"], 2000)

  jwt.validate_document(claims, "my-doc")
  |> expect.to_be_ok()
}

pub fn jwt_validate_document_mismatch_test() {
  let claims = make_test_claims("tenant", "my-doc", ["doc:read"], 2000)

  jwt.validate_document(claims, "other-doc")
  |> assert_error_variant(fn(err) {
    let assert jwt.DocumentMismatch(token, request) = err
    token |> expect.to_equal("my-doc")
    request |> expect.to_equal("other-doc")
  })
}

// -- Scope --

pub fn jwt_validate_scope_present_test() {
  let claims =
    make_test_claims("tenant", "doc", ["doc:read", "doc:write"], 2000)

  jwt.validate_scope(claims, "doc:read")
  |> expect.to_be_ok()

  jwt.validate_scope(claims, "doc:write")
  |> expect.to_be_ok()
}

pub fn jwt_validate_scope_missing_test() {
  let claims = make_test_claims("tenant", "doc", ["doc:read"], 2000)

  jwt.validate_scope(claims, "doc:write")
  |> assert_error_variant(fn(err) {
    let assert jwt.MissingScope(required, _available) = err
    required |> expect.to_equal("doc:write")
  })
}

// -- has_scope helpers --

pub fn jwt_has_scope_test() {
  let claims =
    make_test_claims("tenant", "doc", ["doc:read", "doc:write"], 2000)

  jwt.has_scope(claims, "doc:read") |> expect.to_be_true()
  jwt.has_scope(claims, "doc:write") |> expect.to_be_true()
  jwt.has_scope(claims, "summary:write") |> expect.to_be_false()
}

pub fn jwt_has_read_scope_test() {
  let claims_with = make_test_claims("tenant", "doc", ["doc:read"], 2000)
  let claims_without = make_test_claims("tenant", "doc", ["doc:write"], 2000)

  jwt.has_read_scope(claims_with) |> expect.to_be_true()
  jwt.has_read_scope(claims_without) |> expect.to_be_false()
}

pub fn jwt_has_write_scope_test() {
  let claims_with = make_test_claims("tenant", "doc", ["doc:write"], 2000)
  let claims_without = make_test_claims("tenant", "doc", ["doc:read"], 2000)

  jwt.has_write_scope(claims_with) |> expect.to_be_true()
  jwt.has_write_scope(claims_without) |> expect.to_be_false()
}

pub fn jwt_has_summary_write_scope_test() {
  let claims_with = make_test_claims("tenant", "doc", ["summary:write"], 2000)
  let claims_without = make_test_claims("tenant", "doc", ["doc:write"], 2000)

  jwt.has_summary_write_scope(claims_with) |> expect.to_be_true()
  jwt.has_summary_write_scope(claims_without) |> expect.to_be_false()
}

// -- Combined validation --

pub fn jwt_validate_connection_claims_test() {
  let claims =
    make_test_claims("my-tenant", "my-doc", ["doc:read", "doc:write"], 2000)

  jwt.validate_connection_claims(claims, "my-tenant", "my-doc", 1500)
  |> expect.to_be_ok()
}

pub fn jwt_validate_connection_claims_expired_test() {
  let claims = make_test_claims("my-tenant", "my-doc", ["doc:read"], 1000)

  jwt.validate_connection_claims(claims, "my-tenant", "my-doc", 1500)
  |> assert_error_variant(fn(err) {
    let assert jwt.TokenExpired(_, _) = err
    Nil
  })
}

pub fn jwt_validate_connection_claims_tenant_mismatch_test() {
  let claims = make_test_claims("my-tenant", "my-doc", ["doc:read"], 2000)

  jwt.validate_connection_claims(claims, "other-tenant", "my-doc", 1500)
  |> assert_error_variant(fn(err) {
    let assert jwt.TenantMismatch(_, _) = err
    Nil
  })
}

pub fn jwt_validate_read_access_test() {
  let claims = make_test_claims("tenant", "doc", ["doc:read"], 2000)

  jwt.validate_read_access(claims, "tenant", "doc", 1500)
  |> expect.to_be_ok()
}

pub fn jwt_validate_read_access_missing_scope_test() {
  let claims = make_test_claims("tenant", "doc", ["doc:write"], 2000)

  jwt.validate_read_access(claims, "tenant", "doc", 1500)
  |> assert_error_variant(fn(err) {
    let assert jwt.MissingScope(required, _) = err
    required |> expect.to_equal("doc:read")
  })
}

pub fn jwt_validate_write_access_test() {
  let claims =
    make_test_claims("tenant", "doc", ["doc:read", "doc:write"], 2000)

  jwt.validate_write_access(claims, "tenant", "doc", 1500)
  |> expect.to_be_ok()
}

pub fn jwt_validate_write_access_missing_write_scope_test() {
  let claims = make_test_claims("tenant", "doc", ["doc:read"], 2000)

  jwt.validate_write_access(claims, "tenant", "doc", 1500)
  |> assert_error_variant(fn(err) {
    let assert jwt.MissingScope(required, _) = err
    required |> expect.to_equal("doc:write")
  })
}

pub fn jwt_validate_summary_access_test() {
  let claims =
    make_test_claims("tenant", "doc", ["doc:read", "summary:write"], 2000)

  jwt.validate_summary_access(claims, "tenant", "doc", 1500)
  |> expect.to_be_ok()
}

// -- Error formatting --

pub fn jwt_format_error_test() {
  let error = jwt.TokenExpired(1000, 1500)
  let formatted = jwt.format_error(error)
  formatted |> expect.to_equal("Token expired at 1000 (current time: 1500)")
}

pub fn jwt_error_to_http_code_test() {
  jwt.error_to_http_code(jwt.TokenExpired(0, 0)) |> expect.to_equal(401)
  jwt.error_to_http_code(jwt.TenantMismatch("", "")) |> expect.to_equal(403)
  jwt.error_to_http_code(jwt.DocumentMismatch("", "")) |> expect.to_equal(403)
  jwt.error_to_http_code(jwt.MissingScope("", [])) |> expect.to_equal(403)
  jwt.error_to_http_code(jwt.MissingClaim("")) |> expect.to_equal(401)
  jwt.error_to_http_code(jwt.InvalidClaim("", "")) |> expect.to_equal(401)
}

// -- Scope constants --

pub fn jwt_scope_constants_test() {
  jwt.scope_doc_read |> expect.to_equal("doc:read")
  jwt.scope_doc_write |> expect.to_equal("doc:write")
  jwt.scope_summary_write |> expect.to_equal("summary:write")
}

// ─────────────────────────────────────────────────────────────────────────────
// Session Logic Tests
// ─────────────────────────────────────────────────────────────────────────────

// -- Feature Negotiation --

pub fn negotiate_features_both_support_test() {
  let server = dict.from_list([#("submit_signals_v2", True)])
  let client = dict.from_list([#("submit_signals_v2", True)])

  let result = session_logic.negotiate_features(server, client)
  dict.get(result, "submit_signals_v2") |> expect.to_equal(Ok(True))
}

pub fn negotiate_features_client_declines_test() {
  let server = dict.from_list([#("submit_signals_v2", True)])
  let client = dict.from_list([#("submit_signals_v2", False)])

  let result = session_logic.negotiate_features(server, client)
  dict.get(result, "submit_signals_v2") |> expect.to_equal(Ok(False))
}

pub fn negotiate_features_client_unspecified_test() {
  let server = dict.from_list([#("submit_signals_v2", True)])
  let client = dict.new()

  let result = session_logic.negotiate_features(server, client)
  dict.get(result, "submit_signals_v2") |> expect.to_equal(Ok(True))
}

// -- Version Negotiation --

pub fn negotiate_version_match_test() {
  let result =
    session_logic.negotiate_version(["^0.1.0", "^1.0.0"], ["^0.1.0"])
  result |> expect.to_equal("0.1.0")
}

pub fn negotiate_version_1_0_test() {
  let result =
    session_logic.negotiate_version(["^0.1.0", "^1.0.0"], ["^1.0.0"])
  result |> expect.to_equal("1.0.0")
}

pub fn negotiate_version_fallback_test() {
  let result =
    session_logic.negotiate_version(["^0.1.0", "^1.0.0"], ["^2.0.0"])
  result |> expect.to_equal("0.1.0")
}

pub fn negotiate_version_empty_client_test() {
  let result = session_logic.negotiate_version(["^0.1.0", "^1.0.0"], [])
  result |> expect.to_equal("0.1.0")
}

// -- Validate Summarize Contents --

pub fn validate_summarize_contents_all_present_test() {
  let contents =
    dict.from_list([
      #("handle", coerce("h1")),
      #("message", coerce("msg")),
      #("parents", coerce([])),
      #("head", coerce("sha")),
    ])

  session_logic.validate_summarize_contents(contents)
  |> expect.to_be_ok()
}

pub fn validate_summarize_contents_missing_fields_test() {
  let contents = dict.from_list([#("handle", coerce("h1"))])

  case session_logic.validate_summarize_contents(contents) {
    Error(msg) -> {
      string.contains(msg, "message") |> expect.to_be_true()
      string.contains(msg, "parents") |> expect.to_be_true()
      string.contains(msg, "head") |> expect.to_be_true()
    }
    Ok(_) -> panic as "Expected Error, got Ok"
  }
}

// -- Determine Signal Recipients --

pub fn signal_recipients_broadcast_test() {
  let result =
    session_logic.determine_signal_recipients(
      "sender",
      option.None,
      option.None,
      option.None,
      ["sender", "a", "b", "c"],
    )
  result |> expect.to_equal(["a", "b", "c"])
}

pub fn signal_recipients_targeted_test() {
  let result =
    session_logic.determine_signal_recipients(
      "sender",
      option.Some(["a", "c"]),
      option.None,
      option.None,
      ["sender", "a", "b", "c"],
    )
  result |> expect.to_equal(["a", "c"])
}

pub fn signal_recipients_ignored_test() {
  let result =
    session_logic.determine_signal_recipients(
      "sender",
      option.None,
      option.Some(["b"]),
      option.None,
      ["sender", "a", "b", "c"],
    )
  result |> expect.to_equal(["a", "c"])
}

pub fn signal_recipients_single_target_test() {
  let result =
    session_logic.determine_signal_recipients(
      "sender",
      option.None,
      option.None,
      option.Some("b"),
      ["sender", "a", "b", "c"],
    )
  result |> expect.to_equal(["b"])
}

pub fn signal_recipients_single_target_is_sender_test() {
  let result =
    session_logic.determine_signal_recipients(
      "sender",
      option.None,
      option.None,
      option.Some("sender"),
      ["sender", "a", "b"],
    )
  result |> expect.to_equal([])
}

pub fn signal_recipients_targeted_excludes_sender_test() {
  let result =
    session_logic.determine_signal_recipients(
      "sender",
      option.Some(["sender", "a"]),
      option.None,
      option.None,
      ["sender", "a", "b"],
    )
  result |> expect.to_equal(["a"])
}

// -- Add To History --

pub fn add_to_history_prepends_test() {
  let history = [2, 1]
  let result = session_logic.add_to_history(3, history, 10)
  result |> expect.to_equal([3, 2, 1])
}

pub fn add_to_history_trims_to_max_test() {
  let history = [3, 2, 1]
  let result = session_logic.add_to_history(4, history, 3)
  result |> expect.to_equal([4, 3, 2])
}

// ─────────────────────────────────────────────────────────────────────────────
// Nack Tests
// ─────────────────────────────────────────────────────────────────────────────

pub fn nack_unknown_client_test() {
  let n = nack.unknown_client("client-42")
  n.content.code |> expect.to_equal(400)
  n.content.message |> expect.to_equal("Unknown client: client-42")
  n.sequence_number |> expect.to_equal(-1)
}

pub fn nack_read_only_client_test() {
  let n = nack.read_only_client(option.None)
  n.content.code |> expect.to_equal(400)
  n.content.message |> expect.to_equal("Client is in read-only mode")
}

pub fn nack_invalid_csn_test() {
  let n = nack.invalid_csn(5, 3, option.None)
  n.content.code |> expect.to_equal(400)
  string.contains(n.content.message, "5") |> expect.to_be_true()
  string.contains(n.content.message, "3") |> expect.to_be_true()
}

pub fn nack_invalid_rsn_test() {
  let n = nack.invalid_rsn(10, 5, option.None)
  n.content.code |> expect.to_equal(400)
  string.contains(n.content.message, "10") |> expect.to_be_true()
  string.contains(n.content.message, "5") |> expect.to_be_true()
}

pub fn nack_error_type_roundtrip_test() {
  nack.nack_error_type_to_string(nack.BadRequestError)
  |> nack.nack_error_type_from_string()
  |> expect.to_equal(Ok(nack.BadRequestError))

  nack.nack_error_type_to_string(nack.ThrottlingError)
  |> nack.nack_error_type_from_string()
  |> expect.to_equal(Ok(nack.ThrottlingError))
}

// ─────────────────────────────────────────────────────────────────────────────
// Signal Normalization Tests
// ─────────────────────────────────────────────────────────────────────────────

pub fn normalize_v2_signal_test() {
  let raw =
    dict.from_list([
      #("content", coerce("hello")),
      #("type", coerce("myType")),
      #("clientConnectionNumber", coerce(42)),
    ])

  let result = signals.normalize_signal(raw)
  result.signal_type |> expect.to_equal(option.Some("myType"))
  result.client_connection_number |> expect.to_equal(option.Some(42))
  result.target_client_id |> expect.to_equal(option.None)
}

pub fn normalize_v1_signal_test() {
  let raw =
    dict.from_list([
      #("address", coerce("")),
      #(
        "contents",
        coerce(
          dict.from_list([
            #("type", coerce("v1Type")),
            #("content", coerce("data")),
          ]),
        ),
      ),
      #("clientBroadcastSignalSequenceNumber", coerce(7)),
    ])

  let result = signals.normalize_signal(raw)
  result.signal_type |> expect.to_equal(option.Some("v1Type"))
  result.client_connection_number |> expect.to_equal(option.Some(7))
  result.targeted_clients |> expect.to_equal(option.None)
}

pub fn normalize_v2_envelope_signal_test() {
  let inner =
    dict.from_list([
      #("content", coerce("payload")),
      #("type", coerce("sigType")),
    ])

  let raw =
    dict.from_list([
      #("signal", coerce(inner)),
      #("targetedClients", coerce(["a", "b"])),
    ])

  let result = signals.normalize_signal(raw)
  result.signal_type |> expect.to_equal(option.Some("sigType"))
  result.targeted_clients |> expect.to_equal(option.Some(["a", "b"]))
}

// Helper for tests - coerce a value to Dynamic
@external(erlang, "gleam_stdlib", "identity")
fn coerce(value: a) -> dynamic.Dynamic
