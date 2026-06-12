import gleam/http
import gleam/http/request
import gleeunit/should
import levee_server
import levee_server/auth
import levee_server/storage
import levee_storage
import wisp/simulate

const tenant = "tenant-a"

const document = "doc-a"

const user = "user-a"

const secret = "phase1-secret"

pub fn valid_token_verifies_test() {
  let token =
    auth.sign_for_test(tenant, document, user, ["doc:read"], secret, 3600)

  auth.verify_token(token, tenant, auth.Secrets(secret, "rotated-secret"))
  |> should.be_ok
}

pub fn expired_token_is_rejected_test() {
  let token =
    auth.sign_for_test(tenant, document, user, ["doc:read"], secret, -1)

  auth.verify_token(token, tenant, auth.Secrets(secret, "rotated-secret"))
  |> should.equal(Error(auth.TokenExpired))
}

pub fn wrong_secret_is_rejected_test() {
  let token =
    auth.sign_for_test(tenant, document, user, ["doc:read"], secret, 3600)

  auth.verify_token(token, tenant, auth.Secrets("wrong", "also-wrong"))
  |> should.equal(Error(auth.InvalidSignature))
}

pub fn wrong_tenant_is_forbidden_test() {
  let token =
    auth.sign_for_test(tenant, document, user, ["doc:read"], secret, 3600)

  auth.verify_token(
    token,
    "other-tenant",
    auth.Secrets(secret, "rotated-secret"),
  )
  |> should.equal(Error(auth.TenantMismatch(tenant, "other-tenant")))
}

pub fn missing_scope_is_forbidden_test() {
  let token =
    auth.sign_for_test(tenant, document, user, ["doc:read"], secret, 3600)
  let assert Ok(claims) =
    auth.verify_token(token, tenant, auth.Secrets(secret, "rotated-secret"))

  auth.require_scopes(claims, ["doc:read", "doc:write"])
  |> should.equal(Error(auth.MissingScopes(["doc:write"])))
}

pub fn health_route_is_native_test() {
  let response =
    simulate.request(http.Get, "/health")
    |> levee_server.handle_request

  response.status
  |> should.equal(200)
  simulate.read_body(response)
  |> should.equal("{\"status\":\"ok\"}")
}

pub fn document_read_route_returns_phoenix_shape_test() {
  storage.ensure_dir_for_test("build/phase1-test-storage")
  let tables = levee_storage.ets_init("build/phase1-test-storage")
  storage.put_tables_for_test(tables)
  let _ = levee_storage.ets_create_document(tables, tenant, document, 7)

  let token =
    auth.sign_for_test(tenant, document, user, ["doc:read"], secret, 3600)
  auth.put_secret_for_test(tenant, secret)

  let response =
    simulate.request(http.Get, "/documents/" <> tenant <> "/" <> document)
    |> request.set_header("authorization", "Bearer " <> token)
    |> levee_server.handle_request

  response.status
  |> should.equal(200)
  simulate.read_body(response)
  |> should.equal(
    "{\"id\":\"doc-a\",\"tenantId\":\"tenant-a\",\"sequenceNumber\":7}",
  )
}
