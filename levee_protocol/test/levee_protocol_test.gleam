import levee_protocol
import levee_protocol/jwt
import levee_protocol/sequencing
import levee_protocol/types
import gleam/dict
import gleam/option
import gleeunit
import gleeunit/should

pub fn main() -> Nil {
  gleeunit.main()
}

// Test new sequence state starts at 0
pub fn new_sequence_state_test() {
  let state = levee_protocol.new_sequence_state()
  levee_protocol.current_sn(state) |> should.equal(0)
  levee_protocol.current_msn(state) |> should.equal(0)
  levee_protocol.client_count(state) |> should.equal(0)
}

// Test client join
pub fn client_join_test() {
  let state = levee_protocol.new_sequence_state()
  let state = levee_protocol.client_join(state, "client-1", 0)

  levee_protocol.client_count(state) |> should.equal(1)
  levee_protocol.is_client_connected(state, "client-1") |> should.be_true()
  levee_protocol.is_client_connected(state, "client-2") |> should.be_false()
}

// Test sequence number assignment
pub fn assign_sequence_number_test() {
  let state = levee_protocol.new_sequence_state()
  let state = levee_protocol.client_join(state, "client-1", 0)

  // Assign first sequence number
  case sequencing.assign_sequence_number(state, "client-1", 1, 0) {
    sequencing.SequenceOk(new_state, assigned_sn, msn) -> {
      assigned_sn |> should.equal(1)
      msn |> should.equal(0)
      levee_protocol.current_sn(new_state) |> should.equal(1)
    }
    sequencing.SequenceError(_) -> {
      should.fail()
    }
  }
}

// Test multiple ops increment SN correctly
pub fn multiple_ops_test() {
  let state = levee_protocol.new_sequence_state()
  let state = levee_protocol.client_join(state, "client-1", 0)

  // First op
  let state = case sequencing.assign_sequence_number(state, "client-1", 1, 0) {
    sequencing.SequenceOk(s, sn, _) -> {
      sn |> should.equal(1)
      s
    }
    sequencing.SequenceError(_) -> panic
  }

  // Second op
  let state = case sequencing.assign_sequence_number(state, "client-1", 2, 1) {
    sequencing.SequenceOk(s, sn, _) -> {
      sn |> should.equal(2)
      s
    }
    sequencing.SequenceError(_) -> panic
  }

  levee_protocol.current_sn(state) |> should.equal(2)
}

// Test invalid CSN is rejected
pub fn invalid_csn_test() {
  let state = levee_protocol.new_sequence_state()
  let state = levee_protocol.client_join(state, "client-1", 0)

  // First op with CSN 1
  let state = case sequencing.assign_sequence_number(state, "client-1", 1, 0) {
    sequencing.SequenceOk(s, _, _) -> s
    sequencing.SequenceError(_) -> panic
  }

  // Try to submit with CSN 1 again (should fail)
  case sequencing.assign_sequence_number(state, "client-1", 1, 1) {
    sequencing.SequenceOk(_, _, _) -> should.fail()
    sequencing.SequenceError(reason) -> {
      case reason {
        sequencing.InvalidCsn(_, _) -> should.be_ok(Ok(Nil))
        _ -> should.fail()
      }
    }
  }
}

// Test client leave
pub fn client_leave_test() {
  let state = levee_protocol.new_sequence_state()
  let state = levee_protocol.client_join(state, "client-1", 0)
  let state = levee_protocol.client_join(state, "client-2", 0)

  levee_protocol.client_count(state) |> should.equal(2)

  let state = levee_protocol.client_leave(state, "client-1")

  levee_protocol.client_count(state) |> should.equal(1)
  levee_protocol.is_client_connected(state, "client-1") |> should.be_false()
  levee_protocol.is_client_connected(state, "client-2") |> should.be_true()
}

// Test MSN calculation with multiple clients
pub fn msn_calculation_test() {
  let state = levee_protocol.new_sequence_state()

  // Client 1 joins at RSN 0
  let state = levee_protocol.client_join(state, "client-1", 0)

  // Client 1 submits op (CSN 1, RSN 0)
  let state = case sequencing.assign_sequence_number(state, "client-1", 1, 0) {
    sequencing.SequenceOk(s, _, msn) -> {
      // MSN should still be 0 (client-1's RSN was 0)
      msn |> should.equal(0)
      s
    }
    sequencing.SequenceError(_) -> panic
  }

  // Client 2 joins at current SN (1)
  let state = levee_protocol.client_join(state, "client-2", 1)

  // Client 2 submits op (CSN 1, RSN 1)
  let state = case sequencing.assign_sequence_number(state, "client-2", 1, 1) {
    sequencing.SequenceOk(s, _, msn) -> {
      // MSN should still be 0 (client-1's last RSN was 0)
      msn |> should.equal(0)
      s
    }
    sequencing.SequenceError(_) -> panic
  }

  // Client 1 submits op (CSN 2, RSN 2) - now caught up
  case sequencing.assign_sequence_number(state, "client-1", 2, 2) {
    sequencing.SequenceOk(_, _, msn) -> {
      // MSN should advance to 1 (min of client-1's RSN=2, client-2's RSN=1)
      msn |> should.equal(1)
    }
    sequencing.SequenceError(_) -> panic
  }
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

// Test expiration validation
pub fn jwt_validate_expiration_valid_test() {
  let claims = make_test_claims("tenant", "doc", ["doc:read"], 2000)

  jwt.validate_expiration(claims, 1500)
  |> should.be_ok()
}

pub fn jwt_validate_expiration_expired_test() {
  let claims = make_test_claims("tenant", "doc", ["doc:read"], 1000)

  case jwt.validate_expiration(claims, 1500) {
    Ok(_) -> should.fail()
    Error(jwt.TokenExpired(exp, current)) -> {
      exp |> should.equal(1000)
      current |> should.equal(1500)
    }
    Error(_) -> should.fail()
  }
}

// Test tenant validation
pub fn jwt_validate_tenant_match_test() {
  let claims = make_test_claims("my-tenant", "doc", ["doc:read"], 2000)

  jwt.validate_tenant(claims, "my-tenant")
  |> should.be_ok()
}

pub fn jwt_validate_tenant_mismatch_test() {
  let claims = make_test_claims("my-tenant", "doc", ["doc:read"], 2000)

  case jwt.validate_tenant(claims, "other-tenant") {
    Ok(_) -> should.fail()
    Error(jwt.TenantMismatch(token, request)) -> {
      token |> should.equal("my-tenant")
      request |> should.equal("other-tenant")
    }
    Error(_) -> should.fail()
  }
}

// Test document validation
pub fn jwt_validate_document_match_test() {
  let claims = make_test_claims("tenant", "my-doc", ["doc:read"], 2000)

  jwt.validate_document(claims, "my-doc")
  |> should.be_ok()
}

pub fn jwt_validate_document_mismatch_test() {
  let claims = make_test_claims("tenant", "my-doc", ["doc:read"], 2000)

  case jwt.validate_document(claims, "other-doc") {
    Ok(_) -> should.fail()
    Error(jwt.DocumentMismatch(token, request)) -> {
      token |> should.equal("my-doc")
      request |> should.equal("other-doc")
    }
    Error(_) -> should.fail()
  }
}

// Test scope validation
pub fn jwt_validate_scope_present_test() {
  let claims = make_test_claims("tenant", "doc", ["doc:read", "doc:write"], 2000)

  jwt.validate_scope(claims, "doc:read")
  |> should.be_ok()

  jwt.validate_scope(claims, "doc:write")
  |> should.be_ok()
}

pub fn jwt_validate_scope_missing_test() {
  let claims = make_test_claims("tenant", "doc", ["doc:read"], 2000)

  case jwt.validate_scope(claims, "doc:write") {
    Ok(_) -> should.fail()
    Error(jwt.MissingScope(required, _available)) -> {
      required |> should.equal("doc:write")
    }
    Error(_) -> should.fail()
  }
}

// Test has_scope helpers
pub fn jwt_has_scope_test() {
  let claims = make_test_claims("tenant", "doc", ["doc:read", "doc:write"], 2000)

  jwt.has_scope(claims, "doc:read") |> should.be_true()
  jwt.has_scope(claims, "doc:write") |> should.be_true()
  jwt.has_scope(claims, "summary:write") |> should.be_false()
}

pub fn jwt_has_read_scope_test() {
  let claims_with = make_test_claims("tenant", "doc", ["doc:read"], 2000)
  let claims_without = make_test_claims("tenant", "doc", ["doc:write"], 2000)

  jwt.has_read_scope(claims_with) |> should.be_true()
  jwt.has_read_scope(claims_without) |> should.be_false()
}

pub fn jwt_has_write_scope_test() {
  let claims_with = make_test_claims("tenant", "doc", ["doc:write"], 2000)
  let claims_without = make_test_claims("tenant", "doc", ["doc:read"], 2000)

  jwt.has_write_scope(claims_with) |> should.be_true()
  jwt.has_write_scope(claims_without) |> should.be_false()
}

pub fn jwt_has_summary_write_scope_test() {
  let claims_with = make_test_claims("tenant", "doc", ["summary:write"], 2000)
  let claims_without = make_test_claims("tenant", "doc", ["doc:write"], 2000)

  jwt.has_summary_write_scope(claims_with) |> should.be_true()
  jwt.has_summary_write_scope(claims_without) |> should.be_false()
}

// Test combined validation
pub fn jwt_validate_connection_claims_test() {
  let claims =
    make_test_claims("my-tenant", "my-doc", ["doc:read", "doc:write"], 2000)

  jwt.validate_connection_claims(claims, "my-tenant", "my-doc", 1500)
  |> should.be_ok()
}

pub fn jwt_validate_connection_claims_expired_test() {
  let claims = make_test_claims("my-tenant", "my-doc", ["doc:read"], 1000)

  case jwt.validate_connection_claims(claims, "my-tenant", "my-doc", 1500) {
    Ok(_) -> should.fail()
    Error(jwt.TokenExpired(_, _)) -> should.be_ok(Ok(Nil))
    Error(_) -> should.fail()
  }
}

pub fn jwt_validate_connection_claims_tenant_mismatch_test() {
  let claims = make_test_claims("my-tenant", "my-doc", ["doc:read"], 2000)

  case jwt.validate_connection_claims(claims, "other-tenant", "my-doc", 1500) {
    Ok(_) -> should.fail()
    Error(jwt.TenantMismatch(_, _)) -> should.be_ok(Ok(Nil))
    Error(_) -> should.fail()
  }
}

pub fn jwt_validate_read_access_test() {
  let claims = make_test_claims("tenant", "doc", ["doc:read"], 2000)

  jwt.validate_read_access(claims, "tenant", "doc", 1500)
  |> should.be_ok()
}

pub fn jwt_validate_read_access_missing_scope_test() {
  let claims = make_test_claims("tenant", "doc", ["doc:write"], 2000)

  case jwt.validate_read_access(claims, "tenant", "doc", 1500) {
    Ok(_) -> should.fail()
    Error(jwt.MissingScope(required, _)) -> {
      required |> should.equal("doc:read")
    }
    Error(_) -> should.fail()
  }
}

pub fn jwt_validate_write_access_test() {
  let claims = make_test_claims("tenant", "doc", ["doc:read", "doc:write"], 2000)

  jwt.validate_write_access(claims, "tenant", "doc", 1500)
  |> should.be_ok()
}

pub fn jwt_validate_write_access_missing_write_scope_test() {
  let claims = make_test_claims("tenant", "doc", ["doc:read"], 2000)

  case jwt.validate_write_access(claims, "tenant", "doc", 1500) {
    Ok(_) -> should.fail()
    Error(jwt.MissingScope(required, _)) -> {
      required |> should.equal("doc:write")
    }
    Error(_) -> should.fail()
  }
}

pub fn jwt_validate_summary_access_test() {
  let claims =
    make_test_claims("tenant", "doc", ["doc:read", "summary:write"], 2000)

  jwt.validate_summary_access(claims, "tenant", "doc", 1500)
  |> should.be_ok()
}

// Test error formatting
pub fn jwt_format_error_test() {
  let error = jwt.TokenExpired(1000, 1500)
  let formatted = jwt.format_error(error)
  formatted |> should.equal("Token expired at 1000 (current time: 1500)")
}

pub fn jwt_error_to_http_code_test() {
  jwt.error_to_http_code(jwt.TokenExpired(0, 0)) |> should.equal(401)
  jwt.error_to_http_code(jwt.TenantMismatch("", "")) |> should.equal(403)
  jwt.error_to_http_code(jwt.DocumentMismatch("", "")) |> should.equal(403)
  jwt.error_to_http_code(jwt.MissingScope("", [])) |> should.equal(403)
  jwt.error_to_http_code(jwt.MissingClaim("")) |> should.equal(401)
  jwt.error_to_http_code(jwt.InvalidClaim("", "")) |> should.equal(401)
}

// Test scope constants
pub fn jwt_scope_constants_test() {
  jwt.scope_doc_read |> should.equal("doc:read")
  jwt.scope_doc_write |> should.equal("doc:write")
  jwt.scope_summary_write |> should.equal("summary:write")
}
