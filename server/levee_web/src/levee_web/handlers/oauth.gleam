//// OAuth handler — stub for OAuth provider flow.
////
//// Routes:
//// - GET /auth/:provider       — redirect to OAuth provider
//// - GET /auth/:provider/callback — handle OAuth callback
////
//// This handler is a 501 stub. The full OAuth flow requires integration
//// with the levee_oauth package and the vestibule library, which needs
//// further investigation before porting from Elixir.

import levee_web/context.{type Context}
import levee_web/json_helpers
import wisp.{type Request, type Response}

/// GET /auth/:provider — begin OAuth flow (redirect to provider).
pub fn request(_req: Request, _ctx: Context, _provider: String) -> Response {
  json_helpers.error_response(
    501,
    "not_implemented",
    "OAuth flow not yet ported to Gleam",
  )
}

/// GET /auth/:provider/callback — handle OAuth callback.
pub fn callback(_req: Request, _ctx: Context, _provider: String) -> Response {
  json_helpers.error_response(
    501,
    "not_implemented",
    "OAuth callback not yet ported to Gleam",
  )
}
