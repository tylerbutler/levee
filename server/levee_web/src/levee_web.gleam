//// Levee web server — wisp/mist HTTP + beryl WebSocket.
////
//// This is the main entry point that replaces Phoenix.

import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/option.{None}
import levee_web/config
import levee_web/context.{Context}
import levee_web/router
import logging
import mist
import wisp
import wisp_mist

pub fn main() {
  // Configure logging
  logging.configure()
  logging.set_level(logging.Info)
  wisp.configure_logger()

  let port = config.get_port()

  // TODO: Phase 5 — start real actors
  let ctx =
    Context(
      static_path: "../priv/static",
      tenant_secrets: None,
      session_store: None,
      storage: None,
    )

  // Start HTTP server
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
