import gleam/dict
import gleam/option
import gleam/string
import levee_protocol
import levee_protocol/jwt
import levee_protocol/sequencing
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
