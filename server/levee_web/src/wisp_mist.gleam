//// Mist adapter for Wisp.
////
//// Vendored from tylerbutler/wisp fork (wisp_mist subpackage).
//// Converts wisp request handlers to mist-compatible handlers.

import exception
import gleam/bytes_tree
import gleam/http/request.{type Request as HttpRequest}
import gleam/http/response.{type Response as HttpResponse}
import gleam/option
import gleam/result
import gleam/string
import mist
import wisp
import wisp/internal
import wisp/websocket

/// Convert a Wisp request handler into a function that can be run with the Mist
/// web server.
///
/// # Examples
///
/// ```gleam
/// pub fn main() {
///   let secret_key_base = "..."
///   let assert Ok(_) =
///     handle_request
///     |> wisp_mist.handler(secret_key_base)
///     |> mist.new
///     |> mist.port(8000)
///     |> mist.start
///   process.sleep_forever()
/// }
/// ```
///
pub fn handler(
  handler: fn(wisp.Request) -> wisp.Response,
  secret_key_base: String,
) -> fn(HttpRequest(mist.Connection)) -> HttpResponse(mist.ResponseData) {
  fn(mist_request: HttpRequest(_)) {
    let connection =
      internal.make_connection(mist_body_reader(mist_request), secret_key_base)
    let wisp_request = request.set_body(mist_request, connection)

    use <- exception.defer(fn() {
      let assert Ok(_) = wisp.delete_temporary_files(wisp_request)
    })

    let response = handler(wisp_request)

    case response.body {
      wisp.WebSocket(upgrade) -> mist_websocket_upgrade(mist_request, upgrade)
      wisp.Text(text) ->
        response.set_body(response, mist.Bytes(bytes_tree.from_string(text)))
      wisp.Bytes(bytes) -> response.set_body(response, mist.Bytes(bytes))
      wisp.File(path:, offset:, limit:) ->
        mist_send_file(response, path, offset, limit)
    }
  }
}

fn mist_body_reader(request: HttpRequest(mist.Connection)) -> internal.Reader {
  case mist.stream(request) {
    Error(_) -> fn(_) { Ok(internal.ReadingFinished) }
    Ok(stream) -> fn(size) { wrap_mist_chunk(stream(size)) }
  }
}

fn wrap_mist_chunk(
  chunk: Result(mist.Chunk, mist.ReadError),
) -> Result(internal.Read, Nil) {
  chunk
  |> result.replace_error(Nil)
  |> result.map(fn(chunk) {
    case chunk {
      mist.Done -> internal.ReadingFinished
      mist.Chunk(data, consume) ->
        internal.Chunk(data, fn(size) { wrap_mist_chunk(consume(size)) })
    }
  })
}

fn mist_send_file(
  response: HttpResponse(wisp.Body),
  path: String,
  offset: Int,
  limit: option.Option(Int),
) -> HttpResponse(mist.ResponseData) {
  case mist.send_file(path, offset:, limit:) {
    Ok(body) -> response.set_body(response, body)
    Error(error) -> {
      wisp.log_error(string.inspect(error))
      response.new(500)
      |> response.set_body(mist.Bytes(bytes_tree.new()))
    }
  }
}

fn mist_websocket_upgrade(
  request: HttpRequest(mist.Connection),
  upgrade: wisp.WebSocketUpgrade,
) -> HttpResponse(mist.ResponseData) {
  let ws = wisp.recover(upgrade)
  let #(on_init, on_message, on_close) = websocket.extract_callbacks(ws)

  mist.websocket(
    request: request,
    on_init: fn(mist_connection) {
      let wisp_connection =
        websocket.make_connection(
          fn(text) {
            mist.send_text_frame(mist_connection, text)
            |> result.map_error(fn(_) { websocket.SendFailed })
          },
          fn(binary) {
            mist.send_binary_frame(mist_connection, binary)
            |> result.map_error(fn(_) { websocket.SendFailed })
          },
          fn() { Ok(Nil) },
        )
      on_init(wisp_connection)
    },
    handler: fn(state, message, mist_connection) {
      let wisp_connection =
        websocket.make_connection(
          fn(text) {
            mist.send_text_frame(mist_connection, text)
            |> result.map_error(fn(_) { websocket.SendFailed })
          },
          fn(binary) {
            mist.send_binary_frame(mist_connection, binary)
            |> result.map_error(fn(_) { websocket.SendFailed })
          },
          fn() { Ok(Nil) },
        )
      let wisp_message = case message {
        mist.Text(text) -> websocket.Text(text)
        mist.Binary(binary) -> websocket.Binary(binary)
        mist.Closed -> websocket.Closed
        mist.Shutdown -> websocket.Shutdown
        mist.Custom(custom) -> websocket.Custom(custom)
      }
      case on_message(state, wisp_message, wisp_connection) {
        websocket.Continue(new_state) -> mist.continue(new_state)
        websocket.Stop -> mist.stop()
        websocket.StopWithError(reason) -> mist.stop_abnormal(reason)
      }
    },
    on_close: on_close,
  )
}
