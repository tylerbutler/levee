import beryl
import beryl/transport/mist as mist_transport
import beryl/wire
import envoy
import gleam/erlang/process
import gleam/http/request
import gleam/int
import gleam/result
import gleam/string
import levee_server/channels/document_channel
import levee_server/proxy
import levee_server/routes/auth_api
import levee_server/routes/read
import levee_server/routes/write
import levee_server/storage
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

  let tables = storage.get_or_init_tables()
  storage.start_periodic_saver(tables)
  let assert Ok(_) = document_channel.ensure_supervisor_started()

  let assert Ok(channels) = beryl.start(beryl.config(wire.phoenix_codec()))
  let assert Ok(_) =
    beryl.register(channels, "document:*:*", document_channel.new(channels))
  let assert Ok(_) =
    beryl.register(channels, "document:*", document_channel.new(channels))

  let http_handler = wisp_mist.handler(handle_request, secret_key_base)
  let ws_config = mist_transport.default_config("/socket/websocket")

  let assert Ok(_) =
    fn(req) {
      case is_websocket_request(req) {
        True ->
          mist_transport.upgrade(req, channels, ws_config, fn() {
            http_handler(req)
          })
        False -> http_handler(req)
      }
    }
    |> mist.new
    |> mist.port(port)
    |> mist.start

  process.sleep_forever()
}

fn is_websocket_request(req) -> Bool {
  let path = "/" <> string.join(request.path_segments(req), "/")
  let upgrade =
    request.get_header(req, "upgrade")
    |> result.unwrap("")
    |> string.lowercase
  let connection =
    request.get_header(req, "connection")
    |> result.unwrap("")
    |> string.lowercase

  path == "/socket/websocket"
  && upgrade == "websocket"
  && string.contains(connection, "upgrade")
}

pub fn handle_request(req: wisp.Request) -> wisp.Response {
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
  case read.handle(req) {
    Ok(response) -> response
    Error(Nil) ->
      case write.handle(req) {
        Ok(response) -> response
        Error(Nil) ->
          case auth_api.handle(req) {
            Ok(response) -> response
            Error(Nil) -> proxy.handle(req)
          }
      }
  }
}
