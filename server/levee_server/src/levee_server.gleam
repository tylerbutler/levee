import beryl
import beryl/transport/mist as mist_transport
import beryl/wire
import envoy
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/int
import gleam/result
import gleam/string
import levee_server/channels/document_channel
import levee_server/proxy
import levee_server/routes/admin_api
import levee_server/routes/auth_api
import levee_server/routes/oauth
import levee_server/routes/read
import levee_server/routes/static
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
  case req.method {
    http.Options -> wisp.no_content() |> with_cors
    _ -> route_request(req) |> with_cors
  }
}

fn route_request(req: wisp.Request) -> wisp.Response {
  case read.handle(req) {
    Ok(response) -> response
    Error(Nil) ->
      case write.handle(req) {
        Ok(response) -> response
        Error(Nil) ->
          case auth_api.handle(req) {
            Ok(response) -> response
            Error(Nil) ->
              case oauth.handle(req) {
                Ok(response) -> response
                Error(Nil) ->
                  case admin_api.handle(req) {
                    Ok(response) -> response
                    Error(Nil) ->
                      case static.handle(req) {
                        Ok(response) -> response
                        Error(Nil) ->
                          case wisp.path_segments(req) {
                            ["api", ..] -> static.not_found_json()
                            _ -> proxy.handle(req)
                          }
                      }
                  }
              }
          }
      }
  }
}

fn with_cors(response: wisp.Response) -> wisp.Response {
  response
  |> wisp.set_header("access-control-allow-origin", "*")
  |> wisp.set_header(
    "access-control-allow-methods",
    "GET, POST, PUT, PATCH, DELETE, OPTIONS",
  )
  |> wisp.set_header(
    "access-control-allow-headers",
    "authorization, content-type",
  )
}

/// Exposes the OAuth state store for route tests.
pub fn oauth_store_for_test() {
  oauth.oauth_store_for_test()
}
