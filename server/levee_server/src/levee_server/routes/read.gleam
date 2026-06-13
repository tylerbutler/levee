import gleam/http
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import levee_server/auth
import levee_server/storage
import levee_storage

@external(erlang, "levee_server_ffi", "session_alive")
fn session_alive(tenant_id: String, document_id: String) -> Bool

import levee_storage/types.{
  type Blob, type Commit, type Delta, type Document, type Ref, type Tree,
  NotFound,
}
import wisp

const max_ops_per_request = 2000

pub fn handle(req: wisp.Request) -> Result(wisp.Response, Nil) {
  case req.method, wisp.path_segments(req) {
    http.Get, ["health"] ->
      Ok(json_response(json.object([#("status", json.string("ok"))]), 200))

    http.Get, ["documents", tenant_id, "session", document_id] ->
      native_read_route(req, tenant_id, Some(document_id), fn() {
        document_session(req, tenant_id, document_id)
      })

    http.Get, ["documents", tenant_id, document_id] ->
      native_read_route(req, tenant_id, Some(document_id), fn() {
        document_show(tenant_id, document_id)
      })

    http.Get, ["deltas", tenant_id, document_id] ->
      native_read_route(req, tenant_id, Some(document_id), fn() {
        deltas_index(req, tenant_id, document_id)
      })

    http.Get, ["repos", tenant_id, "git", "blobs", sha] ->
      native_read_route(req, tenant_id, None, fn() {
        blob_show(req, tenant_id, sha)
      })

    http.Get, ["repos", tenant_id, "git", "trees", sha] ->
      native_read_route(req, tenant_id, None, fn() {
        tree_show(req, tenant_id, sha)
      })

    http.Get, ["repos", tenant_id, "git", "commits", sha] ->
      native_read_route(req, tenant_id, None, fn() {
        commit_show(req, tenant_id, sha)
      })

    http.Get, ["repos", tenant_id, "git", "refs"] ->
      native_read_route(req, tenant_id, None, fn() {
        refs_index(req, tenant_id)
      })

    http.Get, ["repos", tenant_id, "git", "refs", ..ref_parts] ->
      native_read_route(req, tenant_id, None, fn() {
        ref_show(req, tenant_id, ref_parts)
      })

    _, _ -> Error(Nil)
  }
}

fn native_read_route(
  req: wisp.Request,
  tenant_id: String,
  document_id: Option(String),
  next: fn() -> wisp.Response,
) -> Result(wisp.Response, Nil) {
  case storage.has_tables() {
    False -> Error(Nil)
    True ->
      case
        auth.verify_request(req, tenant_id, document_id, [auth.scope_doc_read])
      {
        Ok(_) -> Ok(next())
        Error(error) -> Ok(auth.error_response(error))
      }
  }
}

fn document_show(tenant_id: String, document_id: String) -> wisp.Response {
  case storage.get_tables() {
    Error(Nil) -> wisp.internal_server_error()
    Ok(tables) ->
      case levee_storage.ets_get_document(tables, tenant_id, document_id) {
        Ok(document) -> document_json(document) |> json_response(200)
        Error(NotFound) -> error_json("Document not found", 404)
        Error(_) -> wisp.internal_server_error()
      }
  }
}

fn document_session(
  req: wisp.Request,
  tenant_id: String,
  document_id: String,
) -> wisp.Response {
  case storage.get_tables() {
    Error(Nil) -> wisp.internal_server_error()
    Ok(tables) ->
      case levee_storage.ets_get_document(tables, tenant_id, document_id) {
        Ok(_) -> session_json(req, tenant_id, document_id) |> json_response(200)
        Error(NotFound) -> error_json("Document not found", 404)
        Error(_) -> wisp.internal_server_error()
      }
  }
}

fn deltas_index(
  req: wisp.Request,
  tenant_id: String,
  document_id: String,
) -> wisp.Response {
  case storage.get_tables() {
    Error(Nil) -> wisp.internal_server_error()
    Ok(tables) -> {
      let from_sn = query_int(req, "from", -1)
      let to_sn = query_optional_int(req, "to")
      case
        levee_storage.ets_get_deltas(
          tables,
          tenant_id,
          document_id,
          from_sn,
          to_sn,
          max_ops_per_request,
        )
      {
        Ok(deltas) -> deltas_json(deltas) |> wisp.json_response(200)
        Error(_) -> wisp.internal_server_error()
      }
    }
  }
}

fn blob_show(req: wisp.Request, tenant_id: String, sha: String) -> wisp.Response {
  case storage.get_tables() {
    Error(Nil) -> wisp.internal_server_error()
    Ok(tables) ->
      case levee_storage.ets_get_blob(tables, tenant_id, sha) {
        Ok(blob) ->
          blob_json(req, tenant_id, blob)
          |> json_response(200)
          |> wisp.set_header("cache-control", "public, max-age=31536000")
        Error(NotFound) -> error_json("Blob not found", 404)
        Error(_) -> wisp.internal_server_error()
      }
  }
}

fn tree_show(req: wisp.Request, tenant_id: String, sha: String) -> wisp.Response {
  case storage.get_tables() {
    Error(Nil) -> wisp.internal_server_error()
    Ok(tables) -> {
      let recursive = query_value(req, "recursive") == Some("1")
      case levee_storage.ets_get_tree(tables, tenant_id, sha, recursive) {
        Ok(tree) -> tree_json(req, tenant_id, tree) |> json_response(200)
        Error(NotFound) -> error_json("Tree not found", 404)
        Error(_) -> wisp.internal_server_error()
      }
    }
  }
}

fn commit_show(
  req: wisp.Request,
  tenant_id: String,
  sha: String,
) -> wisp.Response {
  case storage.get_tables() {
    Error(Nil) -> wisp.internal_server_error()
    Ok(tables) ->
      case levee_storage.ets_get_commit(tables, tenant_id, sha) {
        Ok(commit) -> commit_json(req, tenant_id, commit) |> json_response(200)
        Error(NotFound) -> error_json("Commit not found", 404)
        Error(_) -> wisp.internal_server_error()
      }
  }
}

fn refs_index(req: wisp.Request, tenant_id: String) -> wisp.Response {
  case storage.get_tables() {
    Error(Nil) -> wisp.internal_server_error()
    Ok(tables) ->
      case levee_storage.ets_list_refs(tables, tenant_id) {
        Ok(refs) ->
          json.array(refs, fn(ref) { ref_json(req, tenant_id, ref) })
          |> json_response(200)
        Error(_) -> wisp.internal_server_error()
      }
  }
}

fn ref_show(
  req: wisp.Request,
  tenant_id: String,
  ref_parts: List(String),
) -> wisp.Response {
  case storage.get_tables() {
    Error(Nil) -> wisp.internal_server_error()
    Ok(tables) -> {
      let ref_path = "refs/" <> string.join(ref_parts, "/")
      case levee_storage.ets_get_ref(tables, tenant_id, ref_path) {
        Ok(ref) -> ref_json(req, tenant_id, ref) |> json_response(200)
        Error(NotFound) -> error_json("Reference not found", 404)
        Error(_) -> wisp.internal_server_error()
      }
    }
  }
}

fn document_json(document: Document) -> json.Json {
  json.object([
    #("id", json.string(document.id)),
    #("tenantId", json.string(document.tenant_id)),
    #("sequenceNumber", json.int(document.sequence_number)),
  ])
}

fn session_json(
  req: wisp.Request,
  tenant_id: String,
  document_id: String,
) -> json.Json {
  let host = base_url(req)
  json.object([
    #("ordererUrl", json.string(host <> "/socket")),
    #("historianUrl", json.string(host <> "/repos/" <> tenant_id)),
    #(
      "deltaStreamUrl",
      json.string(host <> "/deltas/" <> tenant_id <> "/" <> document_id),
    ),
    #("isSessionAlive", json.bool(session_alive(tenant_id, document_id))),
    #("isSessionActive", json.bool(session_alive(tenant_id, document_id))),
  ])
}

fn deltas_json(deltas: List(Delta)) -> String {
  let messages = deltas |> list.map(delta_json_string) |> string.join(",")
  "{\"value\":[" <> messages <> "]}"
}

fn delta_json_string(delta: Delta) -> String {
  let client_id = case delta.client_id {
    Some(id) -> json.string(id) |> json.to_string
    None -> "null"
  }
  let base = [
    "\"sequenceNumber\":" <> int.to_string(delta.sequence_number),
    "\"clientSequenceNumber\":" <> int.to_string(delta.client_sequence_number),
    "\"minimumSequenceNumber\":" <> int.to_string(delta.minimum_sequence_number),
    "\"clientId\":" <> client_id,
    "\"referenceSequenceNumber\":"
      <> int.to_string(delta.reference_sequence_number),
    "\"type\":" <> json.to_string(json.string(delta.op_type)),
    "\"contents\":" <> storage.dynamic_to_json(delta.contents),
    "\"metadata\":" <> storage.dynamic_to_json(delta.metadata),
    "\"timestamp\":" <> int.to_string(delta.timestamp),
  ]
  let fields = case delta.op_type {
    "join" | "leave" ->
      list.append(base, [
        "\"data\":"
        <> json.to_string(json.string(storage.dynamic_to_json(delta.contents))),
      ])
    _ -> base
  }
  "{" <> string.join(fields, ",") <> "}"
}

fn blob_json(req: wisp.Request, tenant_id: String, blob: Blob) -> json.Json {
  json.object([
    #("sha", json.string(blob.sha)),
    #("size", json.int(blob.size)),
    #("content", json.string(storage.dynamic_to_base64(blob.content))),
    #("encoding", json.string("base64")),
    #("url", json.string(blob_url(req, tenant_id, blob.sha))),
  ])
}

fn tree_json(req: wisp.Request, tenant_id: String, tree: Tree) -> json.Json {
  json.object([
    #("sha", json.string(tree.sha)),
    #("url", json.string(tree_url(req, tenant_id, tree.sha))),
    #(
      "tree",
      json.array(tree.tree, fn(entry) {
        let entry_url = case entry.entry_type {
          "blob" -> json.string(blob_url(req, tenant_id, entry.sha))
          "tree" -> json.string(tree_url(req, tenant_id, entry.sha))
          _ -> json.null()
        }
        json.object([
          #("path", json.string(entry.path)),
          #("mode", json.string(entry.mode)),
          #("sha", json.string(entry.sha)),
          #("type", json.string(entry.entry_type)),
          #("url", entry_url),
        ])
      }),
    ),
  ])
}

fn commit_json(
  req: wisp.Request,
  tenant_id: String,
  commit: Commit,
) -> json.Json {
  json.object([
    #("sha", json.string(commit.sha)),
    #(
      "tree",
      json.object([
        #("sha", json.string(commit.tree)),
        #("url", json.string(tree_url(req, tenant_id, commit.tree))),
      ]),
    ),
    #(
      "parents",
      json.array(commit.parents, fn(parent) {
        json.object([
          #("sha", json.string(parent)),
          #("url", json.string(commit_url(req, tenant_id, parent))),
        ])
      }),
    ),
    #("message", json.nullable(commit.message, json.string)),
    #("author", dynamic_json(commit.author)),
    #("committer", dynamic_json(commit.committer)),
    #("url", json.string(commit_url(req, tenant_id, commit.sha))),
  ])
}

fn ref_json(req: wisp.Request, tenant_id: String, ref: Ref) -> json.Json {
  json.object([
    #("ref", json.string(ref.ref)),
    #(
      "object",
      json.object([
        #("sha", json.string(ref.sha)),
        #("type", json.string("commit")),
        #("url", json.string(commit_url(req, tenant_id, ref.sha))),
      ]),
    ),
    #("url", json.string(ref_url(req, tenant_id, ref.ref))),
  ])
}

fn dynamic_json(value: a) -> json.Json {
  storage.dynamic_to_json(value)
  |> storage.json_fragment
}

fn query_int(req: wisp.Request, key: String, default: Int) -> Int {
  case query_value(req, key) {
    Some(value) -> int.parse(value) |> result.unwrap(default)
    None -> default
  }
}

fn query_optional_int(req: wisp.Request, key: String) -> Option(Int) {
  case query_value(req, key) {
    Some(value) -> int.parse(value) |> result.map(Some) |> result.unwrap(None)
    None -> None
  }
}

fn query_value(req: wisp.Request, key: String) -> Option(String) {
  case list.key_find(wisp.get_query(req), key) {
    Ok(value) -> Some(value)
    Error(Nil) -> None
  }
}

fn error_json(message: String, status: Int) -> wisp.Response {
  json.object([#("error", json.string(message))]) |> json_response(status)
}

fn json_response(body: json.Json, status: Int) -> wisp.Response {
  body |> json.to_string |> wisp.json_response(status)
}

fn base_url(req: wisp.Request) -> String {
  let scheme = http.scheme_to_string(req.scheme)
  let suffix = case req.port {
    None -> ""
    Some(80) if scheme == "http" -> ""
    Some(443) if scheme == "https" -> ""
    Some(port) -> ":" <> int.to_string(port)
  }
  scheme <> "://" <> req.host <> suffix
}

fn blob_url(req: wisp.Request, tenant_id: String, sha: String) -> String {
  base_url(req) <> "/repos/" <> tenant_id <> "/git/blobs/" <> sha
}

fn tree_url(req: wisp.Request, tenant_id: String, sha: String) -> String {
  base_url(req) <> "/repos/" <> tenant_id <> "/git/trees/" <> sha
}

fn commit_url(req: wisp.Request, tenant_id: String, sha: String) -> String {
  base_url(req) <> "/repos/" <> tenant_id <> "/git/commits/" <> sha
}

fn ref_url(req: wisp.Request, tenant_id: String, ref_path: String) -> String {
  let path = case string.starts_with(ref_path, "refs/") {
    True -> string.drop_start(ref_path, 5)
    False -> ref_path
  }
  base_url(req) <> "/repos/" <> tenant_id <> "/git/refs/" <> path
}
