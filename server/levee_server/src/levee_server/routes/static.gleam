import gleam/http
import gleam/http/response.{Response}
import gleam/json
import gleam/string
import wisp

@external(erlang, "levee_server_ffi", "static_dir")
fn static_dir(name: String) -> String

@external(erlang, "levee_server_ffi", "read_file")
fn read_file(path: String) -> Result(String, Nil)

pub fn handle(req: wisp.Request) -> Result(wisp.Response, Nil) {
  case req.method, wisp.path_segments(req) {
    http.Get, [] -> Ok(redirect_302("/admin"))
    http.Get, ["admin"] | http.Get, ["admin", ..] ->
      Ok(spa(req, "admin", "/admin"))
    http.Get, ["sandbag"] | http.Get, ["sandbag", ..] ->
      Ok(spa(req, "sandbag", "/sandbag"))
    _, _ -> Error(Nil)
  }
}

pub fn not_found_json() -> wisp.Response {
  json.object([
    #("errors", json.object([#("detail", json.string("Not Found"))])),
  ])
  |> json.to_string
  |> wisp.json_response(404)
}

pub fn internal_server_error_json() -> wisp.Response {
  json.object([
    #(
      "errors",
      json.object([#("detail", json.string("Internal Server Error"))]),
    ),
  ])
  |> json.to_string
  |> wisp.json_response(500)
}

fn spa(req: wisp.Request, name: String, prefix: String) -> wisp.Response {
  let dir = static_dir(name)
  use <- wisp.serve_static(req, under: prefix, from: dir)
  serve_index(name)
}

fn serve_index(name: String) -> wisp.Response {
  let path = static_dir(name) <> "/index.html"
  case read_file(path) {
    Ok(body) -> wisp.html_response(body, 200)
    Error(Nil) -> missing_index(name)
  }
}

fn missing_index(name: String) -> wisp.Response {
  let body = "Missing " <> string.inspect(name) <> " index.html"
  wisp.html_response(body, 500)
}

fn redirect_302(to url: String) -> wisp.Response {
  Response(
    302,
    [#("location", url), #("content-type", "text/plain; charset=utf-8")],
    wisp.Text("You are being redirected: " <> url),
  )
}
