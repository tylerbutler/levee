//// Top-level wisp router — replaces Phoenix.Router.
////
//// Routes are matched via wisp.path_segments and dispatched to handler
//// modules. Auth middleware is applied per-route group.

import gleam/http
import levee_web/context.{type Context}
import levee_web/handlers/admin_spa
import levee_web/handlers/auth
import levee_web/handlers/deltas
import levee_web/handlers/documents
import levee_web/handlers/git
import levee_web/handlers/health
import levee_web/handlers/oauth
import levee_web/handlers/tenant_admin
import levee_web/json_helpers
import levee_web/middleware/admin_auth
import levee_web/middleware/admin_session_auth
import levee_web/middleware/cors
import levee_web/middleware/jwt_auth
import levee_web/middleware/session_auth
import scopes
import wisp.{type Request, type Response}

/// Main request handler — dispatches all HTTP routes.
pub fn handle_request(req: Request, ctx: Context) -> Response {
  use <- wisp.log_request(req)
  use <- cors.apply(req)
  use <- wisp.serve_static(req, under: "/admin/assets", from: ctx.static_path)

  case wisp.path_segments(req) {
    // ── Public ──────────────────────────────────────────────────────
    ["health"] -> health.index(req)

    // ── Auth API (public) ──────────────────────────────────────────
    ["api", "auth", "register"] ->
      require_method(req, http.Post, fn() { auth.register(req, ctx) })
    ["api", "auth", "login"] ->
      require_method(req, http.Post, fn() { auth.login(req, ctx) })

    // ── Auth API (session required) ────────────────────────────────
    ["api", "auth", "me"] ->
      require_method(req, http.Get, fn() {
        use session_ctx <- session_auth.require(req, ctx)
        auth.me(req, session_ctx)
      })
    ["api", "auth", "logout"] ->
      require_method(req, http.Post, fn() {
        use session_ctx <- session_auth.require(req, ctx)
        auth.logout(req, session_ctx)
      })

    // ── Documents (write access) ───────────────────────────────────
    ["documents", tenant_id] ->
      require_method(req, http.Post, fn() {
        use auth_ctx <- jwt_auth.require(
          req,
          tenant_id,
          [scopes.DocRead, scopes.DocWrite],
          ctx,
        )
        documents.create(req, auth_ctx)
      })

    // ── Documents (read access) ────────────────────────────────────
    ["documents", tenant_id, "session", doc_id] ->
      require_method(req, http.Get, fn() {
        use auth_ctx <- jwt_auth.require(req, tenant_id, [scopes.DocRead], ctx)
        documents.session(req, auth_ctx, doc_id)
      })
    ["documents", tenant_id, doc_id] ->
      require_method(req, http.Get, fn() {
        use auth_ctx <- jwt_auth.require(req, tenant_id, [scopes.DocRead], ctx)
        documents.show(req, auth_ctx, doc_id)
      })

    // ── Deltas (read access) ───────────────────────────────────────
    ["deltas", tenant_id, doc_id] ->
      require_method(req, http.Get, fn() {
        use auth_ctx <- jwt_auth.require(req, tenant_id, [scopes.DocRead], ctx)
        deltas.index(req, auth_ctx, doc_id)
      })

    // ── Git storage (read) ─────────────────────────────────────────
    ["repos", tenant_id, "git", "blobs", sha] ->
      require_method(req, http.Get, fn() {
        use _auth_ctx <- jwt_auth.require(req, tenant_id, [scopes.DocRead], ctx)
        git.show_blob(req, ctx, tenant_id, sha)
      })
    ["repos", tenant_id, "git", "trees", sha] ->
      require_method(req, http.Get, fn() {
        use _auth_ctx <- jwt_auth.require(req, tenant_id, [scopes.DocRead], ctx)
        git.show_tree(req, ctx, tenant_id, sha)
      })
    ["repos", tenant_id, "git", "commits", sha] ->
      require_method(req, http.Get, fn() {
        use _auth_ctx <- jwt_auth.require(req, tenant_id, [scopes.DocRead], ctx)
        git.show_commit(req, ctx, tenant_id, sha)
      })

    // ── Git refs (read + write) ────────────────────────────────────
    ["repos", tenant_id, "git", "refs"] ->
      case req.method {
        http.Get -> {
          use _auth_ctx <- jwt_auth.require(
            req,
            tenant_id,
            [scopes.DocRead],
            ctx,
          )
          git.list_refs(req, ctx, tenant_id)
        }
        http.Post -> {
          use _auth_ctx <- jwt_auth.require(
            req,
            tenant_id,
            [scopes.DocRead, scopes.SummaryWrite],
            ctx,
          )
          git.create_ref(req, ctx, tenant_id)
        }
        _ -> wisp.method_not_allowed([http.Get, http.Post])
      }
    ["repos", tenant_id, "git", "refs", ..rest] ->
      case req.method {
        http.Get -> {
          use _auth_ctx <- jwt_auth.require(
            req,
            tenant_id,
            [scopes.DocRead],
            ctx,
          )
          git.show_ref(req, ctx, tenant_id, rest)
        }
        http.Patch -> {
          use _auth_ctx <- jwt_auth.require(
            req,
            tenant_id,
            [scopes.DocRead, scopes.SummaryWrite],
            ctx,
          )
          git.update_ref(req, ctx, tenant_id, rest)
        }
        _ -> wisp.method_not_allowed([http.Get, http.Patch])
      }

    // ── Git storage (write — summary access) ───────────────────────
    ["repos", tenant_id, "git", "blobs"] ->
      require_method(req, http.Post, fn() {
        use _auth_ctx <- jwt_auth.require(
          req,
          tenant_id,
          [scopes.DocRead, scopes.SummaryWrite],
          ctx,
        )
        git.create_blob(req, ctx, tenant_id)
      })
    ["repos", tenant_id, "git", "trees"] ->
      require_method(req, http.Post, fn() {
        use _auth_ctx <- jwt_auth.require(
          req,
          tenant_id,
          [scopes.DocRead, scopes.SummaryWrite],
          ctx,
        )
        git.create_tree(req, ctx, tenant_id)
      })
    ["repos", tenant_id, "git", "commits"] ->
      require_method(req, http.Post, fn() {
        use _auth_ctx <- jwt_auth.require(
          req,
          tenant_id,
          [scopes.DocRead, scopes.SummaryWrite],
          ctx,
        )
        git.create_commit(req, ctx, tenant_id)
      })

    // ── Admin API (admin key auth) ─────────────────────────────────
    ["api", "admin", "tenants"] ->
      case req.method {
        http.Get -> {
          use <- admin_auth.require(req)
          tenant_admin.index(req, ctx)
        }
        http.Post -> {
          use <- admin_auth.require(req)
          tenant_admin.create(req, ctx)
        }
        _ -> wisp.method_not_allowed([http.Get, http.Post])
      }
    ["api", "admin", "tenants", id] ->
      case req.method {
        http.Get -> {
          use <- admin_auth.require(req)
          tenant_admin.show(req, ctx, id)
        }
        http.Delete -> {
          use <- admin_auth.require(req)
          tenant_admin.delete(req, ctx, id)
        }
        _ -> wisp.method_not_allowed([http.Get, http.Delete])
      }
    ["api", "admin", "tenants", id, "secrets", slot] ->
      require_method(req, http.Post, fn() {
        use <- admin_auth.require(req)
        tenant_admin.regenerate_secret(req, ctx, id, slot)
      })

    // ── Tenant admin (session auth for admin UI) ───────────────────
    ["api", "tenants"] ->
      case req.method {
        http.Get -> {
          use _session_ctx <- admin_session_auth.require(req, ctx)
          tenant_admin.index(req, ctx)
        }
        http.Post -> {
          use _session_ctx <- admin_session_auth.require(req, ctx)
          tenant_admin.create(req, ctx)
        }
        _ -> wisp.method_not_allowed([http.Get, http.Post])
      }
    ["api", "tenants", id] ->
      case req.method {
        http.Get -> {
          use _session_ctx <- admin_session_auth.require(req, ctx)
          tenant_admin.show(req, ctx, id)
        }
        http.Delete -> {
          use _session_ctx <- admin_session_auth.require(req, ctx)
          tenant_admin.delete(req, ctx, id)
        }
        _ -> wisp.method_not_allowed([http.Get, http.Delete])
      }
    ["api", "tenants", id, "secrets", slot] ->
      require_method(req, http.Post, fn() {
        use _session_ctx <- admin_session_auth.require(req, ctx)
        tenant_admin.regenerate_secret(req, ctx, id, slot)
      })

    // ── OAuth ──────────────────────────────────────────────────────
    ["auth", provider] ->
      require_method(req, http.Get, fn() { oauth.request(req, ctx, provider) })
    ["auth", provider, "callback"] ->
      require_method(req, http.Get, fn() { oauth.callback(req, ctx, provider) })

    // ── Admin SPA catch-all ────────────────────────────────────────
    ["admin"] -> admin_spa.index(req, ctx)
    ["admin", ..] -> admin_spa.index(req, ctx)

    _ -> json_helpers.not_found()
  }
}

fn require_method(
  req: Request,
  method: http.Method,
  handler: fn() -> Response,
) -> Response {
  case req.method == method {
    True -> handler()
    False -> wisp.method_not_allowed([method])
  }
}
