import envoy
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/http
import gleam/http/request
import gleam/json
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import levee_server/auth
import levee_server/storage
import password
import session
import session_store
import tenant
import user
import wisp

const auth_data_dir = "build/levee-server-auth-store"

const dummy_hash = "$pbkdf2-sha256$600000$AAAAAAAAAAAAAAAAAAAAAA==$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

const token_expires_in = 3600

@external(erlang, "levee_server_ffi", "get_auth_store")
fn ffi_get_auth_store() -> Result(Subject(session_store.Message), Nil)

@external(erlang, "levee_server_ffi", "put_auth_store")
fn ffi_put_auth_store(store: Subject(session_store.Message)) -> Nil

@external(erlang, "levee_server_ffi", "list_tenants")
fn ffi_list_tenants() -> List(String)

pub fn handle(req: wisp.Request) -> Result(wisp.Response, Nil) {
  case req.method, wisp.path_segments(req) {
    http.Post, ["api", "auth", "register"] -> Ok(register(req))
    http.Post, ["api", "auth", "login"] -> Ok(login(req))
    http.Post, ["api", "auth", "logout"] -> Ok(logout(req))
    http.Get, ["api", "auth", "me"] -> Ok(me(req))
    http.Post, ["api", "tenants", tenant_id, "token-mint"] ->
      Ok(token_mint(req, tenant_id))
    _, _ -> Error(Nil)
  }
}

pub fn store_for_test(store: Subject(session_store.Message)) -> Nil {
  ffi_put_auth_store(store)
}

fn register(req: wisp.Request) -> wisp.Response {
  use body <- wisp.require_string_body(req)
  case json.parse(body, register_decoder()) {
    Error(_) -> error_json("Invalid JSON body", 400)
    Ok(input) ->
      case user.create(input.email, input.password, input.display_name) {
        Ok(created_user) -> {
          let assert Ok(store) = auth_store()
          let user_count = session_store.user_count(store)
          let stored_user = case user_count == 0 {
            True -> user.promote_to_admin(created_user)
            False -> created_user
          }
          session_store.store_user(store, stored_user)
          let new_session = session.create(stored_user.id, "")
          session_store.store_session(store, new_session)
          ensure_membership_in_all_tenants(store, stored_user.id)

          json.object([
            #("user", user_json(stored_user)),
            #("token", json.string(new_session.id)),
          ])
          |> json_response(201)
        }
        Error(user.InvalidEmail) ->
          coded_error("invalid_email", "Invalid email format", 422)
        Error(user.PasswordTooShort) ->
          coded_error(
            "password_too_short",
            "Password must be at least 8 characters",
            422,
          )
        Error(_) -> coded_error("registration_failed", "HashingError", 422)
      }
  }
}

fn login(req: wisp.Request) -> wisp.Response {
  use body <- wisp.require_string_body(req)
  case json.parse(body, login_decoder()) {
    Error(_) -> error_json("Invalid JSON body", 400)
    Ok(input) -> {
      let assert Ok(store) = auth_store()
      let found = session_store.find_user_by_email(store, input.email)
      let hash = case found {
        Ok(found_user) -> found_user.password_hash
        Error(Nil) -> dummy_hash
      }
      let password_valid = password.matches(input.password, hash)
      case found, password_valid {
        Ok(found_user), True -> {
          let new_session = session.create(found_user.id, "")
          session_store.store_session(store, new_session)
          ensure_membership_in_all_tenants(store, found_user.id)

          json.object([
            #("user", user_json(found_user)),
            #("token", json.string(new_session.id)),
          ])
          |> json_response(200)
        }
        _, _ ->
          coded_error("invalid_credentials", "Invalid email or password", 401)
      }
    }
  }
}

fn me(req: wisp.Request) -> wisp.Response {
  case require_session(req) {
    Ok(#(current_user, _)) ->
      json.object([#("user", user_json(current_user))])
      |> json_response(200)
    Error(_) -> unauthorized_session()
  }
}

fn logout(req: wisp.Request) -> wisp.Response {
  case require_session(req) {
    Ok(#(_, current_session)) -> {
      let assert Ok(store) = auth_store()
      session_store.delete_session(store, current_session.id)
      json.object([#("message", json.string("logged out"))])
      |> json_response(200)
    }
    Error(_) -> unauthorized_session()
  }
}

fn token_mint(req: wisp.Request, tenant_id: String) -> wisp.Response {
  case require_session(req) {
    Error(_) -> unauthorized_session()
    Ok(#(current_user, _)) -> {
      use body <- wisp.require_string_body(req)
      case json.parse(body, token_mint_decoder()) {
        Error(_) -> error_json("Missing required field: documentId", 400)
        Ok(input) -> {
          let assert Ok(store) = auth_store()
          case session_store.get_membership(store, current_user.id, tenant_id) {
            Error(Nil) -> error_json("Not a member of this tenant", 403)
            Ok(membership) ->
              case auth.tenant_secrets(tenant_id) {
                Error(auth.UnknownTenant) -> error_json("Tenant not found", 404)
                Error(_) -> error_json("Authentication error", 500)
                Ok(secrets) -> {
                  let requested_scopes = [
                    auth.scope_doc_read,
                    auth.scope_doc_write,
                    "summary:read",
                    auth.scope_summary_write,
                  ]
                  let allowed_scopes =
                    filter_scopes_for_role(requested_scopes, membership.role)
                  let now = auth.now_seconds()
                  let jwt =
                    auth.sign_document_token(
                      tenant_id,
                      input.document_id,
                      current_user.id,
                      allowed_scopes,
                      secrets.secret1,
                      now,
                      token_expires_in,
                    )

                  json.object([
                    #("jwt", json.string(jwt)),
                    #("expiresIn", json.int(token_expires_in)),
                    #(
                      "user",
                      json.object([
                        #("id", json.string(current_user.id)),
                        #("name", json.string(current_user.display_name)),
                      ]),
                    ),
                  ])
                  |> json_response(200)
                }
              }
          }
        }
      }
    }
  }
}

fn require_session(
  req: wisp.Request,
) -> Result(#(user.User, session.Session), Nil) {
  use token <- result.try(extract_bearer(req))
  use store <- result.try(auth_store())
  use current_session <- result.try(session_store.get_session(
    store,
    token,
    None,
  ))
  case session.is_valid(current_session) {
    False -> Error(Nil)
    True -> {
      use current_user <- result.try(session_store.get_user(
        store,
        current_session.user_id,
      ))
      Ok(#(current_user, current_session))
    }
  }
}

fn auth_store() -> Result(Subject(session_store.Message), Nil) {
  case ffi_get_auth_store() {
    Ok(store) -> Ok(store)
    Error(Nil) -> {
      storage.ensure_dir_for_test(auth_data_dir)
      use store <- result.try(
        session_store.start(auth_data_dir)
        |> result.replace_error(Nil),
      )
      ffi_put_auth_store(store)
      Ok(store)
    }
  }
}

fn ensure_membership_in_all_tenants(
  store: Subject(session_store.Message),
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

fn filter_scopes_for_role(
  requested_scopes: List(String),
  role: tenant.Role,
) -> List(String) {
  let role_string = tenant.role_to_string(role)
  let allowed = case role_string {
    "owner" | "admin" -> [
      auth.scope_doc_read,
      auth.scope_doc_write,
      "summary:read",
      auth.scope_summary_write,
    ]
    "member" -> [auth.scope_doc_read, auth.scope_doc_write]
    "viewer" -> [auth.scope_doc_read]
    _ -> []
  }
  requested_scopes
  |> list.filter(fn(scope) { list.contains(allowed, scope) })
}

fn extract_bearer(req: wisp.Request) -> Result(String, Nil) {
  case request.get_header(req, "authorization") {
    Ok("Bearer " <> token) -> Ok(string.trim(token))
    _ -> Error(Nil)
  }
}

type RegisterInput {
  RegisterInput(email: String, password: String, display_name: String)
}

type LoginInput {
  LoginInput(email: String, password: String)
}

type TokenMintInput {
  TokenMintInput(document_id: String)
}

fn register_decoder() -> decode.Decoder(RegisterInput) {
  use email <- decode.field("email", decode.string)
  use password <- decode.field("password", decode.string)
  use display_name <- decode.optional_field("display_name", "", decode.string)
  decode.success(RegisterInput(email:, password:, display_name:))
}

fn login_decoder() -> decode.Decoder(LoginInput) {
  use email <- decode.field("email", decode.string)
  use password <- decode.field("password", decode.string)
  decode.success(LoginInput(email:, password:))
}

fn token_mint_decoder() -> decode.Decoder(TokenMintInput) {
  use document_id <- decode.field("documentId", decode.string)
  decode.success(TokenMintInput(document_id:))
}

fn user_json(user: user.User) -> json.Json {
  json.object([
    #("id", json.string(user.id)),
    #("email", json.string(user.email)),
    #("display_name", json.string(user.display_name)),
    #("github_id", json.nullable(user.github_id, json.string)),
    #("is_admin", json.bool(user.is_admin)),
    #("created_at", json.int(user.created_at)),
  ])
}

fn unauthorized_session() -> wisp.Response {
  json.object([
    #(
      "error",
      json.object([
        #("code", json.string("unauthorized")),
        #("message", json.string("Invalid or expired session")),
      ]),
    ),
  ])
  |> json_response(401)
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
  |> json_response(status)
}

fn error_json(message: String, status: Int) -> wisp.Response {
  json.object([#("error", json.string(message))])
  |> json_response(status)
}

fn json_response(body: json.Json, status: Int) -> wisp.Response {
  body
  |> json.to_string
  |> wisp.json_response(status)
}
