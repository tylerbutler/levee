//// Admin key authentication middleware.
////
//// Validates Bearer tokens against the LEVEE_ADMIN_KEY environment variable.

import envoy
import gleam/crypto
import gleam/result
import levee_web/json_helpers
import levee_web/middleware/jwt_auth
import wisp.{type Request, type Response}

/// Require a valid admin key. Uses constant-time comparison.
pub fn require(req: Request, next: fn() -> Response) -> Response {
  case jwt_auth.extract_bearer_token(req), get_admin_key() {
    Ok(token), Ok(admin_key) -> {
      case crypto.secure_compare(<<token:utf8>>, <<admin_key:utf8>>) {
        True -> next()
        False -> json_helpers.unauthorized("Invalid admin key")
      }
    }
    _, _ -> json_helpers.unauthorized("Invalid admin key")
  }
}

fn get_admin_key() -> Result(String, Nil) {
  envoy.get("LEVEE_ADMIN_KEY")
  |> result.try(fn(key) {
    case key {
      "" -> Error(Nil)
      k -> Ok(k)
    }
  })
}
