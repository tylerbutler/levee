//// JSON response helpers for Levee handlers.

import gleam/json
import wisp.{type Response}

/// Return a JSON response with the given status code and body.
pub fn json_response(status: Int, body: json.Json) -> Response {
  wisp.json_response(json.to_string(body), status)
}

/// Return a JSON error response.
pub fn error_response(
  status: Int,
  error_type: String,
  message: String,
) -> Response {
  json_response(
    status,
    json.object([
      #("error", json.string(error_type)),
      #("message", json.string(message)),
    ]),
  )
}

/// Return a simple 404 JSON response.
pub fn not_found() -> Response {
  error_response(404, "not_found", "Not found")
}

/// Return a 401 unauthorized JSON response.
pub fn unauthorized(message: String) -> Response {
  error_response(401, "unauthorized", message)
}

/// Return a 403 forbidden JSON response.
pub fn forbidden(message: String) -> Response {
  error_response(403, "forbidden", message)
}
