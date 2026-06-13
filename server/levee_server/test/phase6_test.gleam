import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/json
import gleam/option.{None}
import gleam/string
import gleeunit/should
import levee_server
import levee_server/storage
import session
import session_store
import user
import wisp/simulate

@external(erlang, "levee_server_ffi", "set_env")
fn set_env(name: String, value: String) -> Nil

@external(erlang, "levee_server_ffi", "put_auth_store")
fn put_auth_store(store: process.Subject(session_store.Message)) -> Nil

const admin_key = "phase6-admin-key"

pub fn admin_key_routes_reject_missing_or_wrong_bearer_test() {
  set_env("LEVEE_ADMIN_KEY", admin_key)

  let missing_response =
    simulate.request(http.Get, "/api/admin/tenants")
    |> levee_server.handle_request

  missing_response.status
  |> should.equal(401)
  simulate.read_body(missing_response)
  |> should.equal(
    "{\"error\":{\"code\":\"unauthorized\",\"message\":\"Invalid admin key\"}}",
  )

  let wrong_response =
    simulate.request(http.Get, "/api/admin/tenants")
    |> request.set_header("authorization", "Bearer wrong")
    |> levee_server.handle_request

  wrong_response.status
  |> should.equal(401)
}

pub fn tenant_admin_create_with_admin_key_returns_created_tenant_test() {
  set_env("LEVEE_ADMIN_KEY", admin_key)

  let response =
    simulate.request(http.Post, "/api/admin/tenants")
    |> request.set_header("authorization", "Bearer " <> admin_key)
    |> simulate.json_body(
      json.object([#("name", json.string("Phase 6 Tenant"))]),
    )
    |> levee_server.handle_request

  response.status
  |> should.equal(201)
  let body = simulate.read_body(response)
  string.contains(body, "\"tenant\":{")
  |> should.be_true
  string.contains(body, "\"name\":\"Phase 6 Tenant\"")
  |> should.be_true
  string.contains(body, "\"secret1\":")
  |> should.be_true
  string.contains(body, "\"secret2\":")
  |> should.be_true
}

pub fn admin_session_routes_reject_invalid_and_non_admin_sessions_test() {
  let non_admin_token = setup_session_user(False)

  let missing_response =
    simulate.request(http.Get, "/api/tenants/")
    |> levee_server.handle_request

  missing_response.status
  |> should.equal(401)
  simulate.read_body(missing_response)
  |> should.equal(
    "{\"error\":{\"code\":\"unauthorized\",\"message\":\"Invalid or expired session\"}}",
  )

  let forbidden_response =
    simulate.request(http.Get, "/api/tenants/")
    |> request.set_header("authorization", "Bearer " <> non_admin_token)
    |> levee_server.handle_request

  forbidden_response.status
  |> should.equal(403)
  simulate.read_body(forbidden_response)
  |> should.equal(
    "{\"error\":{\"code\":\"forbidden\",\"message\":\"Admin access required\"}}",
  )
}

pub fn admin_spa_fallback_serves_index_html_test() {
  let response =
    simulate.request(http.Get, "/admin/settings/deep-link")
    |> levee_server.handle_request

  response.status
  |> should.equal(200)
  response.get_header(response, "content-type")
  |> should.equal(Ok("text/html; charset=utf-8"))
  simulate.read_body(response)
  |> string.contains("</html>")
  |> should.be_true
}

pub fn root_redirects_to_admin_test() {
  let response =
    simulate.request(http.Get, "/")
    |> levee_server.handle_request

  response.status
  |> should.equal(302)
  response.get_header(response, "location")
  |> should.equal(Ok("/admin"))
}

pub fn api_not_found_returns_phoenix_error_json_shape_test() {
  let response =
    simulate.request(http.Get, "/api/not-a-real-route")
    |> levee_server.handle_request

  response.status
  |> should.equal(404)
  simulate.read_body(response)
  |> should.equal("{\"errors\":{\"detail\":\"Not Found\"}}")
}

pub fn native_responses_include_cors_headers_test() {
  let response =
    simulate.request(http.Get, "/health")
    |> levee_server.handle_request

  response.get_header(response, "access-control-allow-origin")
  |> should.equal(Ok("*"))
}

fn setup_session_user(is_admin: Bool) -> String {
  storage.ensure_dir_for_test("build/phase6-auth-store")
  let assert Ok(store) = session_store.start("build/phase6-auth-store")
  put_auth_store(store)
  let stored_user =
    user.from_db(
      case is_admin {
        True -> "phase6-admin-user"
        False -> "phase6-user"
      },
      "phase6@example.com",
      "hash",
      "Phase Six",
      None,
      is_admin,
      1,
      1,
    )
  let current_session = session.create(stored_user.id, "")
  session_store.store_user(store, stored_user)
  session_store.store_session(store, current_session)
  current_session.id
}
