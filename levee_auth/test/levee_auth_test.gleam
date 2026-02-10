import gleeunit
import gleeunit/should
import levee_auth
import password
import scopes
import token

pub fn main() {
  gleeunit.main()
}

// Password tests

pub fn hash_password_test() {
  let result = password.hash("test_password")
  should.be_ok(result)

  let assert Ok(hash) = result
  // PBKDF2-SHA256 hashes start with $pbkdf2-sha256
  should.be_true(has_prefix(hash, "$pbkdf2-sha256"))
}

pub fn verify_correct_password_test() {
  let assert Ok(hash) = password.hash("correct_password")

  let result = password.verify("correct_password", hash)
  should.equal(result, Ok(True))
}

pub fn verify_wrong_password_test() {
  let assert Ok(hash) = password.hash("correct_password")

  let result = password.verify("wrong_password", hash)
  should.equal(result, Ok(False))
}

pub fn matches_correct_password_test() {
  let assert Ok(hash) = password.hash("my_password")
  should.be_true(password.matches("my_password", hash))
}

pub fn matches_wrong_password_test() {
  let assert Ok(hash) = password.hash("my_password")
  should.be_false(password.matches("wrong_password", hash))
}

// Scopes tests

pub fn scope_to_string_test() {
  should.equal(scopes.to_string(scopes.DocRead), "doc:read")
  should.equal(scopes.to_string(scopes.DocWrite), "doc:write")
  should.equal(scopes.to_string(scopes.SummaryRead), "summary:read")
  should.equal(scopes.to_string(scopes.SummaryWrite), "summary:write")
}

pub fn scope_from_string_test() {
  should.equal(scopes.from_string("doc:read"), Ok(scopes.DocRead))
  should.equal(scopes.from_string("doc:write"), Ok(scopes.DocWrite))
  should.equal(scopes.from_string("invalid"), Error(Nil))
}

pub fn has_scope_test() {
  let user_scopes = [scopes.DocRead, scopes.DocWrite]

  should.be_true(scopes.has_scope(user_scopes, scopes.DocRead))
  should.be_true(scopes.has_scope(user_scopes, scopes.DocWrite))
  should.be_false(scopes.has_scope(user_scopes, scopes.SummaryRead))
}

pub fn filter_for_role_test() {
  let requested = scopes.full_access()

  // Owner gets full access
  let owner_scopes = scopes.filter_for_role(requested, "owner")
  should.equal(owner_scopes, scopes.full_access())

  // Member only gets read-write
  let member_scopes = scopes.filter_for_role(requested, "member")
  should.equal(member_scopes, scopes.read_write())

  // Viewer only gets read
  let viewer_scopes = scopes.filter_for_role(requested, "viewer")
  should.equal(viewer_scopes, scopes.read_only())
}

// Token tests

pub fn create_and_verify_token_test() {
  let secret = "test-secret-key-that-is-long-enough"
  let config = token.default_config(secret)
  let claims = token.read_write_claims("user-1", "tenant-1", "doc-1", config)

  let jwt = token.create(claims, config)

  let result = token.verify(jwt, secret)
  should.be_ok(result)

  let assert Ok(verified_claims) = result
  should.equal(verified_claims.user_id, "user-1")
  should.equal(verified_claims.tenant_id, "tenant-1")
  should.equal(verified_claims.document_id, "doc-1")
  should.equal(verified_claims.scopes, scopes.read_write())
}

pub fn verify_token_wrong_secret_test() {
  let config = token.default_config("correct-secret")
  let claims = token.read_only_claims("user-1", "tenant-1", "doc-1", config)
  let jwt = token.create(claims, config)

  let result = token.verify(jwt, "wrong-secret")
  should.be_error(result)
  should.equal(result, Error(token.InvalidSignature))
}

pub fn token_has_scope_test() {
  let config = token.default_config("secret")
  let claims = token.read_write_claims("user-1", "tenant-1", "doc-1", config)

  should.be_true(token.has_scope(claims, scopes.DocRead))
  should.be_true(token.has_scope(claims, scopes.DocWrite))
  should.be_false(token.has_scope(claims, scopes.SummaryRead))
}

// Top-level API tests

pub fn levee_auth_hash_and_verify_test() {
  let assert Ok(hash) = levee_auth.hash_password("secret123")
  should.be_true(levee_auth.verify_password("secret123", hash))
  should.be_false(levee_auth.verify_password("wrong", hash))
}

pub fn levee_auth_create_and_verify_token_test() {
  let secret = "my-tenant-secret"
  let config = levee_auth.default_token_config(secret)

  let jwt =
    levee_auth.create_document_token(
      "user-42",
      "tenant-99",
      "doc-abc",
      scopes.full_access(),
      config,
    )

  let assert Ok(claims) = levee_auth.verify_token(jwt, secret)
  should.equal(claims.user_id, "user-42")
  should.equal(claims.tenant_id, "tenant-99")
  should.equal(claims.document_id, "doc-abc")
  should.equal(claims.scopes, scopes.full_access())
}

// Helper

fn has_prefix(str: String, prefix: String) -> Bool {
  case str {
    _ if str == prefix -> True
    _ -> {
      let prefix_len = string_length(prefix)
      let str_prefix = string_slice(str, 0, prefix_len)
      str_prefix == prefix
    }
  }
}

@external(erlang, "string", "length")
fn string_length(str: String) -> Int

@external(erlang, "string", "slice")
fn string_slice(str: String, start: Int, length: Int) -> String
