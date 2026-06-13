import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/list
import gleam/option.{type Option, Some}
import gleam/result
import gleam/string
import gleam/uri
import gleeunit/should
import levee_oauth/state_store
import levee_server
import levee_server/routes/oauth
import wisp

@external(erlang, "levee_server_ffi", "set_env")
fn set_env(name: String, value: String) -> Nil

@external(erlang, "levee_server_ffi", "set_github_allowed_users")
fn set_github_allowed_users(users: List(String)) -> Nil

@external(erlang, "levee_server_ffi", "unset_github_allowed_users")
fn unset_github_allowed_users() -> Nil

fn oauth_request(path: String, query: Option(String)) -> wisp.Request {
  request.Request(
    method: http.Get,
    headers: [],
    body: wisp.create_canned_connection(<<>>, "test-secret-key-base"),
    scheme: http.Http,
    host: "localhost",
    port: Some(4000),
    path: path,
    query: query,
  )
}

fn setup_oauth_env() {
  set_env("GITHUB_CLIENT_ID", "client-id")
  set_env("GITHUB_CLIENT_SECRET", "client-secret")
  let _ =
    set_env("GITHUB_REDIRECT_URI", "http://localhost:4000/auth/github/callback")
  Nil
}

pub fn begin_auth_redirects_and_stores_state_test() {
  setup_oauth_env()
  let response =
    levee_server.handle_request(oauth_request(
      "/auth/github",
      Some("redirect_url=/admin/settings%3Bdanger"),
    ))

  response.status
  |> should.equal(302)

  let assert Ok(location) = response.get_header(response, "location")
  string.starts_with(location, "https://github.com//login/oauth/authorize")
  |> should.be_true
  string.contains(location, "client_id=client-id")
  |> should.be_true

  let state = query_value(location, "state")
  { string.length(state) > 0 }
  |> should.be_true

  let assert Ok(store) = levee_server.oauth_store_for_test()
  state_store.validate_and_consume(store, state)
  |> result.is_ok
  |> should.be_true

  let assert Ok(cookie) = response.get_header(response, "set-cookie")
  string.contains(cookie, "oauth_redirect_url=%2Fadmin%2Fsettings%3Bdanger")
  |> should.be_true
  string.contains(cookie, "Max-Age=600")
  |> should.be_true
}

pub fn begin_auth_does_not_store_external_redirect_url_test() {
  setup_oauth_env()
  let response =
    levee_server.handle_request(oauth_request(
      "/auth/github",
      Some("redirect_url=https%3A%2F%2Fattacker.example%2Fcb"),
    ))

  response.status
  |> should.equal(302)

  response.get_header(response, "set-cookie")
  |> result.is_error
  |> should.be_true
}

pub fn begin_auth_does_not_store_redirect_url_with_crlf_test() {
  setup_oauth_env()
  let response =
    levee_server.handle_request(oauth_request(
      "/auth/github",
      Some("redirect_url=%2F%0D%0ALocation%3A%20https%3A%2F%2Fattacker.example"),
    ))

  response.status
  |> should.equal(302)

  response.get_header(response, "set-cookie")
  |> result.is_error
  |> should.be_true
}

pub fn begin_auth_does_not_store_redirect_url_with_backslash_test() {
  setup_oauth_env()
  let response =
    levee_server.handle_request(oauth_request(
      "/auth/github",
      Some("redirect_url=%2F%5Cattacker.example%2Fcb"),
    ))

  response.status
  |> should.equal(302)

  response.get_header(response, "set-cookie")
  |> result.is_error
  |> should.be_true
}

pub fn callback_rejects_state_mismatch_test() {
  setup_oauth_env()
  let response =
    levee_server.handle_request(oauth_request(
      "/auth/github/callback",
      Some("code=abc123&state=invalid-state"),
    ))

  response.status
  |> should.equal(401)

  let assert wisp.Text(body) = response.body
  string.contains(body, "state_invalid")
  |> should.be_true
}

fn query_value(url: String, name: String) -> String {
  let assert Ok(parsed) = uri.parse(url)
  let assert Some(query) = parsed.query
  let assert Ok(params) = uri.parse_query(query)
  params
  |> list.key_find(name)
  |> result.unwrap("")
}

pub fn github_allowlist_empty_application_config_denies_all_test() {
  set_github_allowed_users([])
  oauth.github_allowed_for_test(Some("anyuser"))
  |> should.be_false
  unset_github_allowed_users()
}
