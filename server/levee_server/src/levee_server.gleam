import beryl
import beryl/transport/mist as mist_transport
import beryl/wire
import envoy
import gleam/erlang/process.{type Subject}
import gleam/http
import gleam/http/request
import gleam/int
import gleam/result
import gleam/string
import levee_documents/supervisor as documents_supervisor
import levee_documents/tenant_secrets
import levee_oauth/state_store as oauth_state_store
import levee_storage.{type Tables}
import session_store
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

const default_dev_secret = "levee-dev-secret-change-in-production"

const sandbag_secret = "dev-tenant-secret-key"

pub type RuntimeTree {
  RuntimeTree(
    tables: Tables,
    tenant_secrets: Subject(tenant_secrets.Message),
    document_supervisor: documents_supervisor.Supervisor,
    auth_store: Subject(session_store.Message),
    oauth_store: Subject(oauth_state_store.Message),
  )
}

@external(erlang, "levee_server_ffi", "get_tenant_secrets_actor")
fn ffi_get_tenant_secrets_actor() -> Result(Subject(tenant_secrets.Message), Nil)

@external(erlang, "levee_server_ffi", "put_tenant_secrets_actor")
fn ffi_put_tenant_secrets_actor(actor: Subject(tenant_secrets.Message)) -> Nil

@external(erlang, "levee_server_ffi", "get_document_supervisor")
fn ffi_get_document_supervisor() -> Result(documents_supervisor.Supervisor, Nil)

@external(erlang, "levee_server_ffi", "put_document_supervisor")
fn ffi_put_document_supervisor(supervisor: documents_supervisor.Supervisor) -> Nil

@external(erlang, "levee_server_ffi", "get_auth_store")
fn ffi_get_auth_store() -> Result(Subject(session_store.Message), Nil)

@external(erlang, "levee_server_ffi", "put_auth_store")
fn ffi_put_auth_store(store: Subject(session_store.Message)) -> Nil

@external(erlang, "levee_server_ffi", "get_oauth_store")
fn ffi_get_oauth_store() -> Result(Subject(oauth_state_store.Message), Nil)

@external(erlang, "levee_server_ffi", "put_oauth_store")
fn ffi_put_oauth_store(store: Subject(oauth_state_store.Message)) -> Nil

pub fn main() -> Nil {
  wisp.configure_logger()

  let port =
    envoy.get("PORT")
    |> result.try(int.parse)
    |> result.unwrap(default_port)

  let secret_key_base =
    envoy.get("SECRET_KEY_BASE")
    |> result.unwrap(wisp.random_string(64))

  let assert Ok(runtime) = start_otp_tree()
  let tables = runtime.tables
  storage.start_periodic_saver(tables)

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

pub fn start_otp_tree() -> Result(RuntimeTree, Nil) {
  let data_dir =
    envoy.get("LEVEE_STORAGE_DATA_DIR")
    |> result.unwrap("priv/storage/dets")
  start_otp_tree_with_data_dir(data_dir)
}

pub fn start_otp_tree_for_test(data_dir: String) -> Result(RuntimeTree, Nil) {
  start_otp_tree_with_data_dir(data_dir)
}

fn start_otp_tree_with_data_dir(data_dir: String) -> Result(RuntimeTree, Nil) {
  storage.ensure_dir_for_test(data_dir)
  let tables = storage.get_or_init_tables_at(data_dir)

  use tenant_actor <- result.try(get_or_start_tenant_secrets())
  register_startup_tenants(tenant_actor)

  use doc_supervisor <- result.try(get_or_start_document_supervisor(tables))
  use auth_store <- result.try(get_or_start_auth_store(data_dir <> "/auth"))
  use oauth_store <- result.try(get_or_start_oauth_store())

  Ok(RuntimeTree(
    tables: tables,
    tenant_secrets: tenant_actor,
    document_supervisor: doc_supervisor,
    auth_store: auth_store,
    oauth_store: oauth_store,
  ))
}

fn get_or_start_tenant_secrets() -> Result(
  Subject(tenant_secrets.Message),
  Nil,
) {
  case ffi_get_tenant_secrets_actor() {
    Ok(actor) -> Ok(actor)
    Error(Nil) -> {
      use actor <- result.try(tenant_secrets.start() |> result.replace_error(Nil))
      ffi_put_tenant_secrets_actor(actor)
      Ok(actor)
    }
  }
}

fn register_startup_tenants(actor: Subject(tenant_secrets.Message)) -> Nil {
  case running_in_prod() {
    True -> Nil
    False -> tenant_secrets.register_tenant(actor, "dev-tenant", default_dev_secret)
  }

  tenant_secrets.register_tenant(actor, "sandbag", sandbag_secret)

  case envoy.get("LEVEE_TENANT_ID"), envoy.get("LEVEE_TENANT_KEY") {
    Ok(id), Ok(secret) -> tenant_secrets.register_tenant(actor, id, secret)
    _, _ -> Nil
  }
}

fn running_in_prod() -> Bool {
  case envoy.get("LEVEE_ENV"), envoy.get("MIX_ENV"), envoy.get("GLEAM_ENV") {
    Ok("prod"), _, _ -> True
    _, Ok("prod"), _ -> True
    _, _, Ok("prod") -> True
    _, _, _ -> False
  }
}

fn get_or_start_document_supervisor(
  tables: Tables,
) -> Result(documents_supervisor.Supervisor, Nil) {
  case ffi_get_document_supervisor() {
    Ok(supervisor) -> Ok(supervisor)
    Error(Nil) -> {
      use supervisor <- result.try(
        documents_supervisor.start(tables) |> result.replace_error(Nil),
      )
      ffi_put_document_supervisor(supervisor)
      Ok(supervisor)
    }
  }
}

fn get_or_start_auth_store(data_dir: String) -> Result(
  Subject(session_store.Message),
  Nil,
) {
  case ffi_get_auth_store() {
    Ok(store) -> Ok(store)
    Error(Nil) -> {
      storage.ensure_dir_for_test(data_dir)
      use store <- result.try(session_store.start(data_dir) |> result.replace_error(Nil))
      ffi_put_auth_store(store)
      Ok(store)
    }
  }
}

fn get_or_start_oauth_store() -> Result(
  Subject(oauth_state_store.Message),
  Nil,
) {
  case ffi_get_oauth_store() {
    Ok(store) -> Ok(store)
    Error(Nil) -> {
      use store <- result.try(
        oauth_state_store.start() |> result.replace_error(Nil),
      )
      ffi_put_oauth_store(store)
      Ok(store)
    }
  }
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
