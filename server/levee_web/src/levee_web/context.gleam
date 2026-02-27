//// Typed request context — replaces Phoenix conn.assigns.
////
//// Threaded through all handlers and middleware. Gradually expanded
//// as we port more of the application from Elixir.

import gleam/erlang/process.{type Subject}
import gleam/option.{type Option}
import session_store
import tenant_secrets
import token
import user.{type User}

/// Application-wide context shared by all request handlers.
pub type Context {
  Context(
    /// Path to priv/static for serving admin SPA and assets
    static_path: String,
    /// Tenant secrets actor for JWT verification (None until Phase 5)
    tenant_secrets: Option(Subject(tenant_secrets.Message)),
    /// Session store actor for user/session management (None until Phase 5)
    session_store: Option(Subject(session_store.Message)),
  )
}

/// Context enriched with JWT claims (after jwt_auth middleware).
pub type AuthenticatedContext {
  AuthenticatedContext(
    ctx: Context,
    claims: token.TokenClaims,
    tenant_id: String,
  )
}

/// Context enriched with session user (after session_auth middleware).
pub type SessionContext {
  SessionContext(ctx: Context, user: User, session_id: String)
}
