//// Top-level wisp router — replaces Phoenix.Router.
////
//// Routes are matched via wisp.path_segments and dispatched to handler
//// modules. Auth middleware is applied per-route group.

import gleam/http
import levee_web/context.{type Context}
import levee_web/handlers/health
import levee_web/json_helpers
import levee_web/middleware/cors
import wisp.{type Request, type Response}

/// Main request handler — dispatches all HTTP routes.
pub fn handle_request(req: Request, ctx: Context) -> Response {
  // Log requests
  use <- wisp.log_request(req)

  // CORS
  use <- cors.apply(req)

  // Serve static files for admin SPA
  use <- wisp.serve_static(req, under: "/admin/assets", from: ctx.static_path)

  // Route dispatch
  case wisp.path_segments(req) {
    // Health check (public)
    ["health"] -> health.index(req)

    // Auth API - public
    ["api", "auth", "register"] -> require_post(req, todo_handler)
    ["api", "auth", "login"] -> require_post(req, todo_handler)

    // Auth API - session auth required
    ["api", "auth", "logout"] -> require_post(req, todo_handler)
    ["api", "auth", "me"] -> require_get(req, todo_handler)

    // Documents - write access
    ["documents", _tenant_id] -> require_post(req, todo_handler)

    // Documents - read access
    ["documents", _tenant_id, "session", _id] -> require_get(req, todo_handler)
    ["documents", _tenant_id, _id] -> require_get(req, todo_handler)

    // Deltas - read access
    ["deltas", _tenant_id, _id] -> require_get(req, todo_handler)

    // Git storage - read operations
    ["repos", _tenant_id, "git", "blobs", _sha] ->
      require_get(req, todo_handler)
    ["repos", _tenant_id, "git", "trees", _sha] ->
      require_get(req, todo_handler)
    ["repos", _tenant_id, "git", "commits", _sha] ->
      require_get(req, todo_handler)
    ["repos", _tenant_id, "git", "refs"] ->
      case req.method {
        http.Get -> todo_handler(req)
        http.Post -> todo_handler(req)
        _ -> wisp.method_not_allowed([http.Get, http.Post])
      }
    ["repos", _tenant_id, "git", "refs", ..] ->
      case req.method {
        http.Get -> todo_handler(req)
        http.Patch -> todo_handler(req)
        _ -> wisp.method_not_allowed([http.Get, http.Patch])
      }

    // Git storage - write operations
    ["repos", _tenant_id, "git", "blobs"] -> require_post(req, todo_handler)
    ["repos", _tenant_id, "git", "trees"] -> require_post(req, todo_handler)
    ["repos", _tenant_id, "git", "commits"] -> require_post(req, todo_handler)

    // Admin API - admin key auth
    ["api", "admin", "tenants"] ->
      case req.method {
        http.Get -> todo_handler(req)
        http.Post -> todo_handler(req)
        _ -> wisp.method_not_allowed([http.Get, http.Post])
      }
    ["api", "admin", "tenants", _id] ->
      case req.method {
        http.Get -> todo_handler(req)
        http.Delete -> todo_handler(req)
        _ -> wisp.method_not_allowed([http.Get, http.Delete])
      }
    ["api", "admin", "tenants", _id, "secrets", _slot] ->
      require_post(req, todo_handler)

    // Tenant admin - session auth (admin UI API)
    ["api", "tenants"] ->
      case req.method {
        http.Get -> todo_handler(req)
        http.Post -> todo_handler(req)
        _ -> wisp.method_not_allowed([http.Get, http.Post])
      }
    ["api", "tenants", _id] ->
      case req.method {
        http.Get -> todo_handler(req)
        http.Delete -> todo_handler(req)
        _ -> wisp.method_not_allowed([http.Get, http.Delete])
      }
    ["api", "tenants", _id, "secrets", _slot] -> require_post(req, todo_handler)

    // OAuth routes
    ["auth", _provider] -> require_get(req, todo_handler)
    ["auth", _provider, "callback"] -> require_get(req, todo_handler)

    // Admin SPA catch-all
    ["admin"] -> todo_handler(req)
    ["admin", ..] -> todo_handler(req)

    _ -> json_helpers.not_found()
  }
}

/// Placeholder handler for routes not yet implemented.
fn todo_handler(_req: Request) -> Response {
  json_helpers.error_response(501, "not_implemented", "Route not yet ported")
}

fn require_get(req: Request, handler: fn(Request) -> Response) -> Response {
  case req.method {
    http.Get -> handler(req)
    _ -> wisp.method_not_allowed([http.Get])
  }
}

fn require_post(req: Request, handler: fn(Request) -> Response) -> Response {
  case req.method {
    http.Post -> handler(req)
    _ -> wisp.method_not_allowed([http.Post])
  }
}
