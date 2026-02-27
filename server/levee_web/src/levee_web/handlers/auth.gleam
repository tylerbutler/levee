//// Auth handlers — register, login, me, logout.
////
//// Ported from LeveeWeb.AuthController (Elixir).

import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/json
import gleam/option.{None, Some}
import levee_web/context.{type Context, type SessionContext}
import levee_web/json_helpers
import password
import session
import session_store
import user.{type User}
import wisp.{type Request, type Response}

/// POST /api/auth/register — create a new user account.
///
/// Request body (JSON):
///   - email: User email address
///   - password: User password (min 8 characters)
///   - display_name (optional): Display name
pub fn register(req: Request, ctx: Context) -> Response {
  use body <- wisp.require_json(req)

  let body_result =
    decode.run(body, {
      use email <- decode.field("email", decode.string)
      use pwd <- decode.field("password", decode.string)
      use display_name <- decode.optional_field(
        "display_name",
        "",
        decode.string,
      )
      decode.success(#(email, pwd, display_name))
    })

  case body_result {
    Error(_) ->
      json_helpers.error_response(
        400,
        "bad_request",
        "Missing required fields: email, password",
      )

    Ok(#(email, pwd, display_name)) ->
      case ctx.session_store {
        None ->
          json_helpers.error_response(
            503,
            "service_unavailable",
            "Auth not configured",
          )

        Some(ss_actor) -> do_register(ss_actor, email, pwd, display_name)
      }
  }
}

/// POST /api/auth/login — authenticate with email and password.
///
/// Request body (JSON):
///   - email: User email address
///   - password: User password
pub fn login(req: Request, ctx: Context) -> Response {
  use body <- wisp.require_json(req)

  let body_result =
    decode.run(body, {
      use email <- decode.field("email", decode.string)
      use pwd <- decode.field("password", decode.string)
      decode.success(#(email, pwd))
    })

  case body_result {
    Error(_) ->
      json_helpers.error_response(
        400,
        "bad_request",
        "Missing required fields: email, password",
      )

    Ok(#(email, pwd)) ->
      case ctx.session_store {
        None ->
          json_helpers.error_response(
            503,
            "service_unavailable",
            "Auth not configured",
          )

        Some(ss_actor) -> do_login(ss_actor, email, pwd)
      }
  }
}

/// GET /api/auth/me — return the current authenticated user.
///
/// Requires session_auth middleware to have set user context.
pub fn me(_req: Request, session_ctx: SessionContext) -> Response {
  json_helpers.json_response(
    200,
    json.object([#("user", user_to_json(session_ctx.user))]),
  )
}

/// POST /api/auth/logout — end the current session.
///
/// Requires session_auth middleware to have set session context.
pub fn logout(_req: Request, session_ctx: SessionContext) -> Response {
  case session_ctx.ctx.session_store {
    None ->
      json_helpers.error_response(
        503,
        "service_unavailable",
        "Auth not configured",
      )

    Some(ss_actor) -> {
      session_store.delete_session(ss_actor, session_ctx.session_id)
      json_helpers.json_response(
        200,
        json.object([#("message", json.string("logged out"))]),
      )
    }
  }
}

// ---------------------------------------------------------------------------
// Private helpers
// ---------------------------------------------------------------------------

/// Execute the registration flow: create user, auto-admin first, store, create session.
fn do_register(
  ss_actor: Subject(session_store.Message),
  email: String,
  pwd: String,
  display_name: String,
) -> Response {
  case user.create(email: email, password: pwd, display_name: display_name) {
    Ok(new_user) -> {
      // Auto-promote first user to admin
      let count = session_store.user_count(ss_actor)
      let new_user = case count {
        0 -> user.promote_to_admin(new_user)
        _ -> new_user
      }

      // Store the user
      session_store.store_user(ss_actor, new_user)

      // Create and store a session
      let new_session = session.create(user_id: new_user.id, tenant_id: "")
      session_store.store_session(ss_actor, new_session)

      json_helpers.json_response(
        201,
        json.object([
          #("user", user_to_json(new_user)),
          #("token", json.string(new_session.id)),
        ]),
      )
    }

    Error(user.InvalidEmail) ->
      json_helpers.error_response(422, "invalid_email", "Invalid email format")

    Error(user.PasswordTooShort) ->
      json_helpers.error_response(
        422,
        "password_too_short",
        "Password must be at least 8 characters",
      )

    Error(_) ->
      json_helpers.error_response(
        422,
        "registration_failed",
        "Failed to create user",
      )
  }
}

/// Execute the login flow: find user, verify password, create session.
///
/// Uses a dummy hash when user is not found to prevent timing-based
/// user enumeration attacks.
fn do_login(
  ss_actor: Subject(session_store.Message),
  email: String,
  pwd: String,
) -> Response {
  // Dummy hash for timing-safe comparison when user not found
  let dummy_hash =
    "$pbkdf2-sha256$600000$AAAAAAAAAAAAAAAAAAAAAA==$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

  let #(maybe_user, hash) = case
    session_store.find_user_by_email(ss_actor, email)
  {
    Ok(found_user) -> #(Some(found_user), found_user.password_hash)
    Error(_) -> #(None, dummy_hash)
  }

  // Always verify to prevent timing attacks
  let password_valid = password.matches(pwd, hash)

  case maybe_user, password_valid {
    Some(found_user), True -> {
      let new_session = session.create(user_id: found_user.id, tenant_id: "")
      session_store.store_session(ss_actor, new_session)

      json_helpers.json_response(
        200,
        json.object([
          #("user", user_to_json(found_user)),
          #("token", json.string(new_session.id)),
        ]),
      )
    }

    _, _ ->
      json_helpers.error_response(
        401,
        "invalid_credentials",
        "Invalid email or password",
      )
  }
}

/// Serialize a User to JSON (excludes password_hash).
fn user_to_json(u: User) -> json.Json {
  json.object([
    #("id", json.string(u.id)),
    #("email", json.string(u.email)),
    #("display_name", json.string(u.display_name)),
    #("github_id", json.nullable(u.github_id, json.string)),
    #("is_admin", json.bool(u.is_admin)),
    #("created_at", json.int(u.created_at)),
  ])
}
