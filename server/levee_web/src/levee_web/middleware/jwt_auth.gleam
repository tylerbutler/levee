//// JWT authentication middleware.
////
//// Extracts Bearer token, verifies with tenant secrets (tries both
//// secret1 and secret2 for key rotation), validates tenant/document
//// match and required scopes.

import gleam/http/request
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import levee_web/context.{
  type AuthenticatedContext, type Context, AuthenticatedContext,
}
import levee_web/json_helpers
import scopes.{type Scope}
import tenant_secrets
import token
import wisp.{type Request, type Response}

/// Require a valid JWT token with the given scopes.
///
/// Extracts tenant_id from the URL. Tries secret1, falls back to secret2.
/// On success, calls `next` with an AuthenticatedContext.
pub fn require(
  req: Request,
  tenant_id: String,
  required_scopes: List(Scope),
  ctx: Context,
  next: fn(AuthenticatedContext) -> Response,
) -> Response {
  use token_str <- require_bearer_token(req)

  case ctx.tenant_secrets {
    None ->
      json_helpers.error_response(500, "server_error", "Auth not configured")
    Some(ts_actor) ->
      case tenant_secrets.get_secrets(ts_actor, tenant_id) {
        Error(_) -> json_helpers.unauthorized("Unknown tenant")
        Ok(#(secret1, secret2)) ->
          verify_with_rotation(
            token_str,
            secret1,
            secret2,
            tenant_id,
            required_scopes,
            ctx,
            next,
          )
      }
  }
}

fn verify_with_rotation(
  token_str: String,
  secret1: String,
  secret2: String,
  tenant_id: String,
  required_scopes: List(Scope),
  ctx: Context,
  next: fn(AuthenticatedContext) -> Response,
) -> Response {
  case token.verify(token_str, secret1) {
    Ok(claims) ->
      validate_and_continue(claims, tenant_id, required_scopes, ctx, next)
    Error(token.InvalidSignature) ->
      case token.verify(token_str, secret2) {
        Ok(claims) ->
          validate_and_continue(claims, tenant_id, required_scopes, ctx, next)
        Error(_) -> json_helpers.unauthorized("Invalid token signature")
      }
    Error(token.TokenExpired) -> json_helpers.unauthorized("Token has expired")
    Error(_) -> json_helpers.unauthorized("Invalid token")
  }
}

/// Require a valid JWT but without scope checks (general authenticated access).
pub fn require_authenticated(
  req: Request,
  tenant_id: String,
  ctx: Context,
  next: fn(AuthenticatedContext) -> Response,
) -> Response {
  require(req, tenant_id, [], ctx, next)
}

fn validate_and_continue(
  claims: token.TokenClaims,
  tenant_id: String,
  required_scopes: List(Scope),
  ctx: Context,
  next: fn(AuthenticatedContext) -> Response,
) -> Response {
  // Validate tenant match
  case claims.tenant_id == tenant_id {
    False ->
      json_helpers.error_response(
        403,
        "forbidden",
        "Token not valid for this tenant",
      )
    True -> {
      // Validate required scopes
      let missing =
        required_scopes
        |> list.filter(fn(scope) { !token.has_scope(claims, scope) })
      case missing {
        [] -> {
          let auth_ctx =
            AuthenticatedContext(ctx: ctx, claims: claims, tenant_id: tenant_id)
          next(auth_ctx)
        }
        missing_scopes -> {
          let scope_names =
            missing_scopes
            |> list.map(scopes.to_string)
            |> string.join(", ")
          json_helpers.error_response(
            403,
            "forbidden",
            "Missing required scopes: " <> scope_names,
          )
        }
      }
    }
  }
}

/// Extract Bearer token from Authorization header.
fn require_bearer_token(req: Request, next: fn(String) -> Response) -> Response {
  case request.get_header(req, "authorization") {
    Ok(value) -> {
      case string.starts_with(value, "Bearer ") {
        True -> {
          let token_str = string.drop_start(value, 7) |> string.trim
          next(token_str)
        }
        False ->
          json_helpers.unauthorized(
            "Invalid Authorization header format. Expected: Bearer <token>",
          )
      }
    }
    Error(_) -> json_helpers.unauthorized("Missing Authorization header")
  }
}

/// Standalone bearer token extraction (reused by other middleware).
pub fn extract_bearer_token(req: Request) -> Result(String, Nil) {
  request.get_header(req, "authorization")
  |> result.try(fn(value) {
    case string.starts_with(value, "Bearer ") {
      True -> Ok(string.drop_start(value, 7) |> string.trim)
      False -> Error(Nil)
    }
  })
}
