import gleam/bit_array
import gleam/crypto
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
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
import levee_storage/types.{type TreeEntry, AlreadyExists, NotFound, TreeEntry}
import wisp

@external(erlang, "levee_server_ffi", "now_iso8601")
fn now_iso8601() -> String

pub fn handle(req: wisp.Request) -> Result(wisp.Response, Nil) {
  case req.method, wisp.path_segments(req) {
    http.Post, ["documents", tenant_id] ->
      native_write_route(
        req,
        tenant_id,
        None,
        [auth.scope_doc_read, auth.scope_doc_write],
        fn() { document_create(req, tenant_id) },
      )

    http.Post, ["repos", tenant_id, "git", "blobs"] ->
      native_write_route(
        req,
        tenant_id,
        None,
        [auth.scope_doc_read, auth.scope_summary_write],
        fn() { blob_create(req, tenant_id) },
      )

    http.Post, ["repos", tenant_id, "git", "trees"] ->
      native_write_route(
        req,
        tenant_id,
        None,
        [auth.scope_doc_read, auth.scope_summary_write],
        fn() { tree_create(req, tenant_id) },
      )

    http.Post, ["repos", tenant_id, "git", "commits"] ->
      native_write_route(
        req,
        tenant_id,
        None,
        [auth.scope_doc_read, auth.scope_summary_write],
        fn() { commit_create(req, tenant_id) },
      )

    http.Post, ["repos", tenant_id, "git", "refs"] ->
      native_write_route(
        req,
        tenant_id,
        None,
        [auth.scope_doc_read, auth.scope_summary_write],
        fn() { ref_create(req, tenant_id) },
      )

    http.Patch, ["repos", tenant_id, "git", "refs", ..ref_parts] ->
      native_write_route(
        req,
        tenant_id,
        None,
        [auth.scope_doc_read, auth.scope_summary_write],
        fn() { ref_update(req, tenant_id, ref_parts) },
      )

    _, _ -> Error(Nil)
  }
}

fn native_write_route(
  req: wisp.Request,
  tenant_id: String,
  document_id: Option(String),
  scopes: List(String),
  next: fn() -> wisp.Response,
) -> Result(wisp.Response, Nil) {
  case storage.has_tables() {
    False -> Error(Nil)
    True ->
      case auth.verify_request(req, tenant_id, document_id, scopes) {
        Ok(_) -> Ok(next())
        Error(auth.UnknownTenant) -> Error(Nil)
        Error(error) -> Ok(auth.error_response(error))
      }
  }
}

fn document_create(req: wisp.Request, tenant_id: String) -> wisp.Response {
  use body <- wisp.require_string_body(req)
  case json.parse(body, document_create_decoder()) {
    Error(_) -> error_json("Invalid JSON body", 400)
    Ok(input) -> {
      let document_id = input.id |> result.unwrap(generate_document_id())
      case storage.get_tables() {
        Error(Nil) -> wisp.internal_server_error()
        Ok(tables) ->
          case
            levee_storage.ets_create_document(
              tables,
              tenant_id,
              document_id,
              input.sequence_number,
            )
          {
            Ok(_) -> {
              case input.summary {
                Some(summary) ->
                  process_initial_summary(
                    tables,
                    tenant_id,
                    document_id,
                    summary,
                  )
                None -> Nil
              }
              case input.enable_discovery {
                True ->
                  json.object([
                    #("id", json.string(document_id)),
                    #("session", session_json(req, tenant_id, document_id)),
                  ])
                  |> json_response(201)
                False ->
                  json.string(document_id)
                  |> json_response(201)
              }
            }
            Error(AlreadyExists) -> error_json("Document already exists", 409)
            Error(error) -> storage_error_response(error, 400)
          }
      }
    }
  }
}

fn blob_create(req: wisp.Request, tenant_id: String) -> wisp.Response {
  use body <- wisp.require_string_body(req)
  case json.parse(body, blob_create_decoder()) {
    Error(_) -> error_json("Missing or invalid content", 400)
    Ok(input) ->
      case decode_blob_content(input.content, input.encoding) {
        Error(reason) -> error_json(reason, 400)
        Ok(content) ->
          case storage.get_tables() {
            Error(Nil) -> wisp.internal_server_error()
            Ok(tables) ->
              case
                levee_storage.ets_create_blob(
                  tables,
                  tenant_id,
                  storage.to_dynamic(content),
                )
              {
                Ok(blob) ->
                  json.object([
                    #("sha", json.string(blob.sha)),
                    #("url", json.string(blob_url(req, tenant_id, blob.sha))),
                  ])
                  |> json_response(201)
                Error(error) -> storage_error_response(error, 400)
              }
          }
      }
  }
}

fn tree_create(req: wisp.Request, tenant_id: String) -> wisp.Response {
  use body <- wisp.require_string_body(req)
  case json.parse(body, tree_create_decoder()) {
    Error(_) -> error_json("Invalid JSON body", 400)
    Ok(input) ->
      case storage.get_tables() {
        Error(Nil) -> wisp.internal_server_error()
        Ok(tables) ->
          case levee_storage.ets_create_tree(tables, tenant_id, input.tree) {
            Ok(tree) -> tree_json(req, tenant_id, tree) |> json_response(201)
            Error(error) -> storage_error_response(error, 400)
          }
      }
  }
}

fn commit_create(req: wisp.Request, tenant_id: String) -> wisp.Response {
  use body <- wisp.require_string_body(req)
  case json.parse(body, commit_create_decoder()) {
    Error(_) -> error_json("Invalid JSON body", 400)
    Ok(input) -> {
      let committer = input.committer |> result.unwrap(default_committer())
      case storage.get_tables() {
        Error(Nil) -> wisp.internal_server_error()
        Ok(tables) ->
          case
            levee_storage.ets_create_commit(
              tables,
              tenant_id,
              input.tree,
              input.parents,
              input.message,
              input.author,
              committer,
            )
          {
            Ok(commit) ->
              commit_json(req, tenant_id, commit) |> json_response(201)
            Error(error) -> storage_error_response(error, 400)
          }
      }
    }
  }
}

fn ref_create(req: wisp.Request, tenant_id: String) -> wisp.Response {
  use body <- wisp.require_string_body(req)
  case json.parse(body, ref_create_decoder()) {
    Error(_) -> error_json("Invalid JSON body", 400)
    Ok(input) ->
      case storage.get_tables() {
        Error(Nil) -> wisp.internal_server_error()
        Ok(tables) ->
          case
            levee_storage.ets_create_ref(
              tables,
              tenant_id,
              input.ref,
              input.sha,
            )
          {
            Ok(ref) -> ref_json(req, tenant_id, ref) |> json_response(201)
            Error(AlreadyExists) -> error_json("Reference already exists", 409)
            Error(error) -> storage_error_response(error, 400)
          }
      }
  }
}

fn ref_update(
  req: wisp.Request,
  tenant_id: String,
  ref_parts: List(String),
) -> wisp.Response {
  use body <- wisp.require_string_body(req)
  case json.parse(body, ref_update_decoder()) {
    Error(_) -> error_json("Invalid JSON body", 400)
    Ok(input) ->
      case storage.get_tables() {
        Error(Nil) -> wisp.internal_server_error()
        Ok(tables) -> {
          let ref_path = "refs/" <> string.join(ref_parts, "/")
          case
            levee_storage.ets_update_ref(tables, tenant_id, ref_path, input.sha)
          {
            Ok(ref) -> ref_json(req, tenant_id, ref) |> json_response(200)
            Error(NotFound) ->
              case
                levee_storage.ets_create_ref(
                  tables,
                  tenant_id,
                  ref_path,
                  input.sha,
                )
              {
                Ok(ref) -> ref_json(req, tenant_id, ref) |> json_response(200)
                Error(error) -> storage_error_response(error, 400)
              }
            Error(error) -> storage_error_response(error, 400)
          }
        }
      }
  }
}

type DocumentCreate {
  DocumentCreate(
    id: Result(String, Nil),
    sequence_number: Int,
    enable_discovery: Bool,
    summary: Option(Dynamic),
  )
}

type BlobCreate {
  BlobCreate(content: String, encoding: Result(String, Nil))
}

type TreeCreate {
  TreeCreate(tree: List(TreeEntry))
}

type CommitCreate {
  CommitCreate(
    tree: String,
    parents: List(String),
    message: Option(String),
    author: Dynamic,
    committer: Result(Dynamic, Nil),
  )
}

type RefCreate {
  RefCreate(ref: String, sha: String)
}

type RefUpdate {
  RefUpdate(sha: String)
}

fn document_create_decoder() -> decode.Decoder(DocumentCreate) {
  use id <- decode.optional_field("id", Error(Nil), optional_string_result())
  use sequence_number <- decode.optional_field("sequenceNumber", 0, decode.int)
  use enable_discovery <- decode.optional_field(
    "enableDiscovery",
    False,
    decode.bool,
  )
  use summary <- decode.optional_field(
    "summary",
    None,
    decode.optional(decode.dynamic),
  )
  decode.success(DocumentCreate(
    id:,
    sequence_number:,
    enable_discovery:,
    summary:,
  ))
}

fn blob_create_decoder() -> decode.Decoder(BlobCreate) {
  use content <- decode.field("content", decode.string)
  use encoding <- decode.optional_field(
    "encoding",
    Error(Nil),
    optional_string_result(),
  )
  decode.success(BlobCreate(content:, encoding:))
}

fn tree_create_decoder() -> decode.Decoder(TreeCreate) {
  use tree <- decode.field("tree", decode.list(tree_entry_decoder()))
  decode.success(TreeCreate(tree:))
}

fn tree_entry_decoder() -> decode.Decoder(TreeEntry) {
  use path <- decode.field("path", decode.string)
  use mode <- decode.optional_field("mode", "100644", decode.string)
  use sha <- decode.field("sha", decode.string)
  use entry_type <- decode.optional_field("type", "blob", decode.string)
  decode.success(TreeEntry(path:, mode:, sha:, entry_type:))
}

fn commit_create_decoder() -> decode.Decoder(CommitCreate) {
  use tree <- decode.field("tree", decode.string)
  use parents <- decode.optional_field(
    "parents",
    [],
    decode.list(decode.string),
  )
  use message <- decode.optional_field(
    "message",
    None,
    decode.optional(decode.string),
  )
  use author <- decode.field("author", decode.dynamic)
  use committer <- decode.optional_field(
    "committer",
    Error(Nil),
    optional_dynamic_result(),
  )
  decode.success(CommitCreate(tree:, parents:, message:, author:, committer:))
}

fn ref_create_decoder() -> decode.Decoder(RefCreate) {
  use ref <- decode.field("ref", decode.string)
  use sha <- decode.field("sha", decode.string)
  decode.success(RefCreate(ref:, sha:))
}

fn ref_update_decoder() -> decode.Decoder(RefUpdate) {
  use sha <- decode.field("sha", decode.string)
  decode.success(RefUpdate(sha:))
}

fn optional_string_result() -> decode.Decoder(Result(String, Nil)) {
  decode.optional(decode.string)
  |> decode.map(fn(value) {
    case value {
      Some(value) -> Ok(value)
      None -> Error(Nil)
    }
  })
}

fn optional_dynamic_result() -> decode.Decoder(Result(Dynamic, Nil)) {
  decode.optional(decode.dynamic)
  |> decode.map(fn(value) {
    case value {
      Some(value) -> Ok(value)
      None -> Error(Nil)
    }
  })
}

fn decode_blob_content(
  content: String,
  encoding: Result(String, Nil),
) -> Result(BitArray, String) {
  case encoding {
    Ok("base64") ->
      bit_array.base64_decode(content)
      |> result.replace_error("Invalid base64 content")
    _ -> Ok(bit_array.from_string(content))
  }
}

fn process_initial_summary(
  tables: levee_storage.Tables,
  tenant_id: String,
  document_id: String,
  summary: Dynamic,
) -> Nil {
  case decode.run(summary, summary_tree_decoder()) {
    Ok(tree) -> {
      let app_summary = dict.get(tree, ".app")
      let protocol_summary = dict.get(tree, ".protocol")
      let app_entries = case app_summary {
        Ok(app) -> build_app_summary_entries(tables, tenant_id, app)
        Error(Nil) -> []
      }
      let protocol_entries = case protocol_summary {
        Ok(protocol) ->
          case build_summary_objects(tables, tenant_id, protocol) {
            Ok(#(sha, _)) -> [TreeEntry(".protocol", "040000", sha, "tree")]
            Error(Nil) -> []
          }
        Error(Nil) -> []
      }
      let entries = list.append(app_entries, protocol_entries)
      case levee_storage.ets_create_tree(tables, tenant_id, entries) {
        Ok(root_tree) -> {
          let author = default_author("Levee", "server@levee.local")
          let assert Ok(commit) =
            levee_storage.ets_create_commit(
              tables,
              tenant_id,
              root_tree.sha,
              [],
              Some("Initial summary"),
              author,
              author,
            )
          let _ =
            levee_storage.ets_create_ref(
              tables,
              tenant_id,
              "refs/heads/" <> document_id,
              commit.sha,
            )
          Nil
        }
        Error(_) -> Nil
      }
    }
    Error(_) -> Nil
  }
}

fn build_app_summary_entries(
  tables: levee_storage.Tables,
  tenant_id: String,
  app_summary: Dynamic,
) -> List(TreeEntry) {
  case decode.run(app_summary, summary_tree_decoder()) {
    Ok(app_tree) ->
      dict.to_list(app_tree)
      |> list.filter_map(fn(entry) {
        let #(path, node) = entry
        case build_summary_objects(tables, tenant_id, node) {
          Ok(#(sha, entry_type)) -> {
            let mode = case entry_type {
              "tree" -> "040000"
              _ -> "100644"
            }
            Ok(TreeEntry(path, mode, sha, entry_type))
          }
          Error(Nil) -> Error(Nil)
        }
      })
    Error(_) -> []
  }
}

fn build_summary_objects(
  tables: levee_storage.Tables,
  tenant_id: String,
  node: Dynamic,
) -> Result(#(String, String), Nil) {
  case decode.run(node, summary_tree_decoder()) {
    Ok(tree) -> {
      let entries =
        dict.to_list(tree)
        |> list.filter_map(fn(entry) {
          let #(path, child) = entry
          case build_summary_objects(tables, tenant_id, child) {
            Ok(#(sha, entry_type)) -> {
              let mode = case entry_type {
                "tree" -> "040000"
                _ -> "100644"
              }
              Ok(TreeEntry(path, mode, sha, entry_type))
            }
            Error(Nil) -> Error(Nil)
          }
        })
      case levee_storage.ets_create_tree(tables, tenant_id, entries) {
        Ok(tree) -> Ok(#(tree.sha, "tree"))
        Error(_) -> Error(Nil)
      }
    }
    Error(_) ->
      case decode.run(node, summary_blob_decoder()) {
        Ok(content) -> {
          let bits = case decode.run(content, decode.string) {
            Ok(text) -> bit_array.from_string(text)
            Error(_) -> bit_array.from_string(storage.dynamic_to_json(content))
          }
          case
            levee_storage.ets_create_blob(
              tables,
              tenant_id,
              storage.to_dynamic(bits),
            )
          {
            Ok(blob) -> Ok(#(blob.sha, "blob"))
            Error(_) -> Error(Nil)
          }
        }
        Error(_) -> Ok(#("", "blob"))
      }
  }
}

fn summary_tree_decoder() -> decode.Decoder(Dict(String, Dynamic)) {
  use summary_type <- decode.field("type", decode.int)
  use tree <- decode.field("tree", decode.dict(decode.string, decode.dynamic))
  case summary_type {
    1 -> decode.success(tree)
    _ -> decode.failure(dict.new(), "SummaryTree")
  }
}

fn summary_blob_decoder() -> decode.Decoder(Dynamic) {
  use summary_type <- decode.field("type", decode.int)
  use content <- decode.field("content", decode.dynamic)
  case summary_type {
    2 -> decode.success(content)
    _ -> decode.failure(storage.to_dynamic(Nil), "SummaryBlob")
  }
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
    #("isSessionAlive", json.bool(False)),
    #("isSessionActive", json.bool(False)),
  ])
}

fn tree_json(
  req: wisp.Request,
  tenant_id: String,
  tree: levee_storage.Tree,
) -> json.Json {
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
  commit: levee_storage.Commit,
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

fn ref_json(
  req: wisp.Request,
  tenant_id: String,
  ref: levee_storage.Ref,
) -> json.Json {
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

fn dynamic_json(value: Dynamic) -> json.Json {
  storage.dynamic_to_json(value)
  |> storage.json_fragment
}

fn default_committer() -> Dynamic {
  default_author("Levee", "server@fluid.local")
}

fn default_author(name: String, email: String) -> Dynamic {
  json.object([
    #("name", json.string(name)),
    #("email", json.string(email)),
    #("date", json.string(now_iso8601())),
  ])
  |> json.to_string
  |> storage.json_string_to_dynamic
}

fn generate_document_id() -> String {
  crypto.strong_random_bytes(16)
  |> bit_array.base16_encode
  |> string.lowercase
}

fn storage_error_response(
  error: levee_storage.StorageError,
  status: Int,
) -> wisp.Response {
  case error {
    AlreadyExists -> error_json("already_exists", status)
    NotFound -> error_json("not_found", status)
    _ -> error_json("storage_error", status)
  }
}

fn error_json(message: String, status: Int) -> wisp.Response {
  json.object([#("error", json.string(message))])
  |> json_response(status)
}

fn json_response(body: json.Json, status: Int) -> wisp.Response {
  body
  |> json.to_string
  |> wisp.json_response(status)
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
