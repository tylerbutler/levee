//// Session-based authentication middleware.
////
//// Validates Bearer tokens as session IDs against the session store.
//// Used for auth endpoints like /api/auth/me and /api/auth/logout.

import gleam/erlang/process
import gleam/option.{None, Some}
import levee_web/context.{type Context, type SessionContext, SessionContext}
import levee_web/json_helpers
import levee_web/middleware/jwt_auth
import session_store
import wisp.{type Request, type Response}

/// Require a valid session. Extracts Bearer token as session ID,
/// looks up session and user, verifies session is valid.
pub fn require(
  req: Request,
  ctx: Context,
  next: fn(SessionContext) -> Response,
) -> Response {
  case ctx.session_store {
    None ->
      json_helpers.error_response(500, "server_error", "Auth not configured")
    Some(ss_actor) -> require_with_actor(req, ctx, ss_actor, next)
  }
}

fn require_with_actor(
  req: Request,
  ctx: Context,
  ss_actor: process.Subject(session_store.Message),
  next: fn(SessionContext) -> Response,
) -> Response {
  case jwt_auth.extract_bearer_token(req) {
    Error(_) -> json_helpers.unauthorized("Invalid or expired session")
    Ok(session_id) ->
      case session_store.get_session(ss_actor, session_id, None) {
        Error(_) -> json_helpers.unauthorized("Invalid or expired session")
        Ok(session) ->
          case session_store.get_user(ss_actor, session.user_id) {
            Error(_) -> json_helpers.unauthorized("Invalid or expired session")
            Ok(user) ->
              next(SessionContext(ctx: ctx, user: user, session_id: session_id))
          }
      }
  }
}
