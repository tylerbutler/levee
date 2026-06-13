import envoy
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import levee_oauth
import levee_oauth/error as oauth_error
import levee_oauth/state_store as oauth_state_store
import session
import session_store
import tenant
import user
import vestibule/auth.{type Auth}
import vestibule/error as vestibule_error
import vestibule/user_info.{UserInfo}
import wisp

const auth_data_dir = "build/levee-server-auth-store"

@external(erlang, "levee_server_ffi", "get_oauth_store")
fn ffi_get_oauth_store() -> Result(
  process.Subject(oauth_state_store.Message),
  Nil,
)

@external(erlang, "levee_server_ffi", "put_oauth_store")
fn ffi_put_oauth_store(store: process.Subject(oauth_state_store.Message)) -> Nil

@external(erlang, "levee_server_ffi", "get_auth_store")
fn ffi_get_auth_store() -> Result(process.Subject(session_store.Message), Nil)

@external(erlang, "levee_server_ffi", "put_auth_store")
fn ffi_put_auth_store(store: process.Subject(session_store.Message)) -> Nil

@external(erlang, "levee_server_ffi", "list_tenants")
fn ffi_list_tenants() -> List(String)

@external(erlang, "levee_server_ffi", "ensure_dir")
fn ensure_dir(path: String) -> Nil

@external(erlang, "levee_server_ffi", "get_github_allowed_users")
fn configured_github_allowed_users() -> Option(List(String))

pub fn handle(req: wisp.Request) -> Result(wisp.Response, Nil) {
  case req.method, wisp.path_segments(req) {
    http.Get, ["auth", provider] -> Ok(request(req, provider))
    http.Get, ["auth", provider, "callback"] -> Ok(callback(req, provider))
    _, _ -> Error(Nil)
  }
}

pub fn oauth_store_for_test() -> Result(
  process.Subject(oauth_state_store.Message),
  Nil,
) {
  oauth_store()
}

pub fn github_allowed_for_test(username: Option(String)) -> Bool {
  check_github_allowed(username)
}

fn request(req: wisp.Request, provider: String) -> wisp.Response {
  let assert Ok(store) = oauth_store()
  case levee_oauth.begin_auth(provider, store) {
    Ok(url) -> {
      let response = redirect(url)
      case query_param(req, "redirect_url") |> result.try(safe_redirect_url) {
        Ok(redirect_url) -> set_oauth_redirect_cookie(response, redirect_url)
        Error(Nil) -> response
      }
    }
    Error(oauth_error.UnknownProvider(_)) ->
      coded_error(
        "unknown_provider",
        "Unknown auth provider: " <> provider,
        404,
      )
    Error(oauth_error.ConfigMissing(_)) ->
      coded_error("oauth_not_configured", "OAuth is not configured", 500)
    Error(_) ->
      coded_error("oauth_error", "Failed to start authentication", 500)
  }
}

fn callback(req: wisp.Request, provider: String) -> wisp.Response {
  case query_param(req, "error") {
    Ok(error_code) -> callback_error(req, provider, error_code)
    Error(Nil) -> callback_success(req, provider)
  }
}

fn callback_success(req: wisp.Request, provider: String) -> wisp.Response {
  case query_param(req, "code"), query_param(req, "state") {
    Ok(code), Ok(state) -> {
      let assert Ok(store) = oauth_store()
      case levee_oauth.complete_auth(provider, code, state, store) {
        Ok(auth) -> handle_successful_auth(req, auth)
        Error(oauth_error.VestibuleError(vestibule_error.StateMismatch)) ->
          coded_error(
            "state_mismatch",
            "Authentication failed, please try again",
            401,
          )
        Error(oauth_error.VestibuleError(vestibule_error.CodeExchangeFailed(_))) ->
          coded_error(
            "auth_failed",
            "Authentication failed, please try again",
            401,
          )
        Error(oauth_error.VestibuleError(vestibule_error.UserInfoFailed(_))) ->
          coded_error(
            "provider_error",
            "Could not fetch profile from provider",
            502,
          )
        Error(oauth_error.StateStoreUnavailable) ->
          coded_error(
            "state_invalid",
            "Authentication failed, please try again",
            401,
          )
        Error(_) -> coded_error("auth_failed", "Authentication failed", 401)
      }
    }
    _, _ -> coded_error("auth_failed", "Authentication failed", 401)
  }
}

fn callback_error(
  req: wisp.Request,
  provider: String,
  error_code: String,
) -> wisp.Response {
  case query_param(req, "state") {
    Error(Nil) -> coded_error("auth_failed", "Authentication failed", 401)
    Ok(state) -> {
      let description =
        query_param(req, "error_description") |> result.unwrap("")
      let assert Ok(store) = oauth_store()
      case
        levee_oauth.complete_auth_error(
          provider,
          state,
          error_code,
          description,
          store,
        )
      {
        Error(oauth_error.VestibuleError(vestibule_error.ProviderError(
          code,
          message,
          _,
        ))) -> {
          let provider_message = case message {
            "" -> code
            _ -> message
          }
          coded_error("oauth_failed", provider_message, 401)
        }
        Error(oauth_error.VestibuleError(vestibule_error.StateMismatch)) ->
          coded_error(
            "state_mismatch",
            "Authentication failed, please try again",
            401,
          )
        Error(_) -> coded_error("auth_failed", "Authentication failed", 401)
        Ok(_) -> coded_error("auth_failed", "Authentication failed", 401)
      }
    }
  }
}

fn handle_successful_auth(req: wisp.Request, auth: Auth) -> wisp.Response {
  let UserInfo(name:, email:, nickname:, ..) = auth.info
  let github_username = nickname
  let display_name = option.or(name, github_username) |> option.unwrap("")
  let email_string = email |> option.unwrap("")

  case check_github_allowed(github_username) {
    False -> {
      let base_url = redirect_url(req, "")
      let error_url =
        append_query(strip_empty_token(base_url), "error", "not_authorized")
      redirect(error_url)
      |> clear_oauth_redirect_cookie
    }
    True -> {
      let assert Ok(store) = auth_store()
      let stored_user = case
        session_store.find_user_by_github_id(store, auth.uid)
      {
        Ok(existing_user) -> existing_user
        Error(Nil) -> {
          let new_user = user.create_oauth(email_string, display_name, auth.uid)
          let new_user = case session_store.user_count(store) == 0 {
            True -> user.promote_to_admin(new_user)
            False -> new_user
          }
          session_store.store_user(store, new_user)
          new_user
        }
      }

      let new_session = session.create(stored_user.id, "")
      session_store.store_session(store, new_session)
      ensure_membership_in_all_tenants(store, stored_user.id)

      redirect(redirect_url(req, new_session.id))
      |> clear_oauth_redirect_cookie
    }
  }
}

fn oauth_store() -> Result(process.Subject(oauth_state_store.Message), Nil) {
  case ffi_get_oauth_store() {
    Ok(store) -> Ok(store)
    Error(Nil) -> {
      use store <- result.try(
        oauth_state_store.start() |> result.replace_error(Nil),
      )
      ffi_put_oauth_store(store)
      Ok(store)
    }
  }
}

fn auth_store() -> Result(process.Subject(session_store.Message), Nil) {
  case ffi_get_auth_store() {
    Ok(store) -> Ok(store)
    Error(Nil) -> {
      ensure_dir(auth_data_dir)
      use store <- result.try(
        session_store.start(auth_data_dir) |> result.replace_error(Nil),
      )
      ffi_put_auth_store(store)
      Ok(store)
    }
  }
}

fn ensure_membership_in_all_tenants(
  store: process.Subject(session_store.Message),
  user_id: String,
) -> Nil {
  case envoy.get("LEVEE_DISABLE_AUTO_MEMBERSHIP") {
    Ok("true") | Ok("1") -> Nil
    _ ->
      ffi_list_tenants()
      |> list.each(fn(tenant_id) {
        case session_store.get_membership(store, user_id, tenant_id) {
          Ok(_) -> Nil
          Error(Nil) ->
            tenant.create_membership(user_id, tenant_id, tenant.Member)
            |> session_store.store_membership(store, _)
        }
      })
  }
}

fn check_github_allowed(username: Option(String)) -> Bool {
  case allowed_users() {
    None -> True
    Some(users) ->
      case username {
        None -> False
        Some(name) -> {
          let downcased = string.lowercase(name)
          list.any(users, fn(allowed) { string.lowercase(allowed) == downcased })
        }
      }
  }
}

fn allowed_users() -> Option(List(String)) {
  case configured_github_allowed_users() {
    Some(users) -> Some(users)
    None -> allowed_users_from_env()
  }
}

fn allowed_users_from_env() -> Option(List(String)) {
  case envoy.get("GITHUB_ALLOWED_USERS") {
    Error(Nil) -> None
    Ok(value) -> {
      let users =
        value
        |> string.split(",")
        |> list.map(string.trim)
        |> list.filter(fn(part) { part != "" })
      case users {
        [] -> None
        _ -> Some(users)
      }
    }
  }
}

fn redirect_url(req: wisp.Request, token: String) -> String {
  let base =
    request.get_cookies(req)
    |> list.key_find("oauth_redirect_url")
    |> result.try(uri.percent_decode)
    |> result.try(safe_redirect_url)
    |> result.unwrap("/admin")
  append_query(base, "token", token)
}

fn safe_redirect_url(url: String) -> Result(String, Nil) {
  case
    string.starts_with(url, "/")
    && !string.starts_with(url, "//")
    && !string.contains(url, "\r")
    && !string.contains(url, "\n")
    && !string.contains(url, "\\")
  {
    True -> Ok(url)
    False -> Error(Nil)
  }
}

fn append_query(url: String, key: String, value: String) -> String {
  let separator = case string.contains(url, "?") {
    True -> "&"
    False -> "?"
  }
  url <> separator <> key <> "=" <> uri.percent_encode(value)
}

fn strip_empty_token(url: String) -> String {
  case string.ends_with(url, "?token=") || string.ends_with(url, "&token=") {
    True -> string.drop_end(url, 7)
    False -> url
  }
}

fn query_param(req: wisp.Request, name: String) -> Result(String, Nil) {
  wisp.get_query(req)
  |> list.key_find(name)
}

fn redirect(url: String) -> wisp.Response {
  wisp.response(302)
  |> wisp.set_header("location", url)
  |> wisp.set_body(wisp.Text("You are being redirected: " <> url))
}

fn set_oauth_redirect_cookie(
  response: wisp.Response,
  redirect_url: String,
) -> wisp.Response {
  response
  |> response.prepend_header(
    "set-cookie",
    "oauth_redirect_url="
      <> uri.percent_encode(redirect_url)
      <> "; Max-Age=600; Path=/; SameSite=Lax",
  )
}

fn clear_oauth_redirect_cookie(response: wisp.Response) -> wisp.Response {
  response
  |> response.prepend_header(
    "set-cookie",
    "oauth_redirect_url=; Max-Age=0; Path=/; SameSite=Lax",
  )
}

fn coded_error(code: String, message: String, status: Int) -> wisp.Response {
  json.object([
    #(
      "error",
      json.object([
        #("code", json.string(code)),
        #("message", json.string(message)),
      ]),
    ),
  ])
  |> json.to_string
  |> wisp.json_response(status)
}
