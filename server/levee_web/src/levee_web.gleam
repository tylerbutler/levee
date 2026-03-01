//// Levee web server — wisp/mist HTTP + beryl WebSocket.
////
//// Main entry point. Starts all actors, builds context, runs mist.

import envoy
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/option.{Some}
import gleam/result
import levee_storage
import levee_web/config
import levee_web/context.{Context}
import levee_web/router
import logging
import mist
import session_store
import tenant_secrets
import wisp
import wisp_mist

pub fn main() {
  logging.configure()
  logging.set_level(logging.Info)
  wisp.configure_logger()

  let port = config.get_port()

  // ── Start actors ───────────────────────────────────────────────
  io.println("Starting Levee actors...")

  // Storage (ETS tables)
  let tables = levee_storage.ets_init()
  io.println("  Storage: ETS tables initialized")

  // Tenant secrets actor
  let assert Ok(ts_actor) = tenant_secrets.start()
  store_tenant_secrets_ref(ts_actor)
  io.println("  Auth: tenant secrets actor started")

  // Session store actor (in-memory user/session management)
  let assert Ok(ss_actor) = session_store.start()
  io.println("  Auth: session store actor started")

  // Elixir Registry + DynamicSupervisor for document sessions
  start_elixir_session_infra()
  io.println("  Documents: Registry + Supervisor started")

  // Register dev tenant if configured
  register_dev_tenant(ts_actor)

  // ── Build context ──────────────────────────────────────────────
  let ctx =
    Context(
      static_path: config.get_static_path(),
      tenant_secrets: Some(ts_actor),
      session_store: Some(ss_actor),
      storage: Some(tables),
    )

  // ── Start HTTP server ──────────────────────────────────────────
  let handler = router.handle_request(_, ctx)

  let assert Ok(_) =
    handler
    |> wisp_mist.handler(config.get_secret_key_base())
    |> mist.new
    |> mist.port(port)
    |> mist.start

  io.println("Levee server running on http://localhost:" <> int.to_string(port))

  process.sleep_forever()
}

/// Start the Elixir Registry and DynamicSupervisor for document sessions.
/// These are required by the Session GenServer (still in Elixir).
@external(erlang, "levee_web_ffi", "start_session_infra")
fn start_elixir_session_infra() -> Nil

/// Store the tenant_secrets actor Subject in persistent_term for global access.
/// This allows the channel FFI to verify JWTs without needing the Subject directly.
@external(erlang, "levee_web_ffi", "store_tenant_secrets_ref")
fn store_tenant_secrets_ref(
  actor: process.Subject(tenant_secrets.Message),
) -> Nil

/// Register a dev tenant if LEVEE_TENANT_ID is set.
fn register_dev_tenant(ts_actor: process.Subject(tenant_secrets.Message)) -> Nil {
  case envoy.get("LEVEE_TENANT_ID") {
    Ok(tenant_id) -> {
      let secret =
        envoy.get("LEVEE_TENANT_KEY")
        |> result.unwrap(tenant_secrets.generate_secret())
      tenant_secrets.register_tenant(ts_actor, tenant_id, secret)
      io.println("  Dev tenant registered: " <> tenant_id)
    }
    Error(_) -> Nil
  }
}
