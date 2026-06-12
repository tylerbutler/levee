import envoy
import gleam/bytes_tree
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/httpc
import gleam/int
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import wisp

/// Hop-by-hop headers that must not be forwarded between proxy and upstream.
const hop_by_hop: List(String) = [
  "connection", "host", "keep-alive", "proxy-authenticate",
  "proxy-authorization", "te", "trailers", "transfer-encoding", "upgrade",
]

const proxy_max_body_size: Int = 100_000_000

/// Forward the incoming request to the Phoenix upstream server and relay the
/// response verbatim.
///
/// Reads PHOENIX_UPSTREAM_PORT from the environment (default: 4001) to
/// determine where the Phoenix server is listening.
pub fn handle(req: wisp.Request) -> wisp.Response {
  let upstream_port =
    envoy.get("PHOENIX_UPSTREAM_PORT")
    |> result.try(int.parse)
    |> result.unwrap(4001)

  case wisp.read_body_bits(wisp.set_max_body_size(req, proxy_max_body_size)) {
    Ok(body) -> {
      let headers = filter_hop_by_hop(req.headers)

      let upstream_req =
        request.new()
        |> request.set_method(req.method)
        |> request.set_scheme(http.Http)
        |> request.set_host("127.0.0.1")
        |> request.set_port(upstream_port)
        |> request.set_path(req.path)
        |> with_query(req.query)
        |> with_headers(headers)
        |> request.set_body(body)

      case httpc.send_bits(upstream_req) {
        Ok(upstream_resp) -> relay_response(upstream_resp)
        Error(_) -> wisp.internal_server_error()
      }
    }

    Error(_) -> wisp.bad_request("Unable to read request body")
  }
}

fn filter_hop_by_hop(
  headers: List(#(String, String)),
) -> List(#(String, String)) {
  list.filter(headers, fn(header) {
    let #(name, _) = header
    !list.contains(hop_by_hop, string.lowercase(name))
  })
}

fn with_query(
  req: request.Request(a),
  query: option.Option(String),
) -> request.Request(a) {
  request.Request(..req, query: query)
}

fn with_headers(
  req: request.Request(a),
  headers: List(#(String, String)),
) -> request.Request(a) {
  request.Request(..req, headers: headers)
}

fn relay_response(upstream: response.Response(BitArray)) -> wisp.Response {
  let body = bytes_tree.from_bit_array(upstream.body)
  let resp =
    wisp.response(upstream.status)
    |> wisp.set_body(wisp.Bytes(body))

  list.fold(filter_hop_by_hop(upstream.headers), resp, fn(acc, header) {
    let #(name, value) = header
    response.set_header(acc, name, value)
  })
}
