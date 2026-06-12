import envoy
import gleam/erlang/process
import gleam/int
import gleam/result
import levee_server/proxy
import mist
import wisp
import wisp/wisp_mist

/// Default HTTP listening port if PORT env var is not set.
pub const default_port: Int = 4000

/// Default upstream Phoenix port if PHOENIX_UPSTREAM_PORT env var is not set.
pub const default_upstream_port: Int = 4001

pub fn main() -> Nil {
  wisp.configure_logger()

  let port =
    envoy.get("PORT")
    |> result.try(int.parse)
    |> result.unwrap(default_port)

  let secret_key_base =
    envoy.get("SECRET_KEY_BASE")
    |> result.unwrap(wisp.random_string(64))

  let assert Ok(_) =
    handle_request
    |> wisp_mist.handler(secret_key_base)
    |> mist.new
    |> mist.port(port)
    |> mist.start

  process.sleep_forever()
}

fn handle_request(req: wisp.Request) -> wisp.Response {
  // ═══════════════════════════════════════════════════════════════════
  // EXTENSION POINT — Phase 1+: add native Wisp routes here so that
  // routes handled natively take precedence over the proxy fallthrough.
  //
  // Example (Phase 1):
  //
  //   case wisp.path_segments(req) {
  //     ["health"] -> health.handle(req)
  //     ["api", "v2", ..] -> native_api.handle(req)
  //     _ -> proxy.handle(req)
  //   }
  //
  // For Phase 0 every request is reverse-proxied to the Phoenix server.
  // ═══════════════════════════════════════════════════════════════════
  proxy.handle(req)
}
