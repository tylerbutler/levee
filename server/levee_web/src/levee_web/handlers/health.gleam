//// Health check handler.

import gleam/json
import levee_web/json_helpers
import wisp.{type Request, type Response}

/// GET /health — returns {"status":"ok"}
pub fn index(_req: Request) -> Response {
  json_helpers.json_response(200, json.object([#("status", json.string("ok"))]))
}
