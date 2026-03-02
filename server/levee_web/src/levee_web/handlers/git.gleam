//// Git storage handler — blobs, trees, commits, refs.
////
//// Implements the Fluid Framework Git Storage Service HTTP API under
//// /repos/:tenant_id/git/...
////
//// Storage calls are stubbed with `todo` — to be wired up when context
//// carries the ETS tables handle.

import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/http/request
import gleam/http/response
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import levee_storage/types
import levee_web/context.{type Context}
import levee_web/json_helpers
import wisp.{type Request, type Response}

// ---------------------------------------------------------------------------
// Blob handlers
// ---------------------------------------------------------------------------

/// GET /repos/:tenant_id/git/blobs/:sha
pub fn show_blob(
  req: Request,
  _ctx: Context,
  tenant_id: String,
  _sha: String,
) -> Response {
  // TODO: wire up storage — levee_storage.ets_get_blob(tables, tenant_id, sha)
  let result: Result(types.Blob, types.StorageError) =
    todo as "storage: get blob"

  case result {
    Ok(blob) -> {
      let encoded_content = encode_blob_content(blob.content)

      json_helpers.json_response(
        200,
        json.object([
          #("sha", json.string(blob.sha)),
          #("size", json.int(blob.size)),
          #("content", json.string(encoded_content)),
          #("encoding", json.string("base64")),
          #("url", json.string(blob_url(req, tenant_id, blob.sha))),
        ]),
      )
      |> response.set_header("cache-control", "public, max-age=31536000")
    }

    Error(types.NotFound) ->
      json_helpers.error_response(404, "not_found", "Blob not found")

    Error(_) ->
      json_helpers.error_response(500, "server_error", "Storage error")
  }
}

/// POST /repos/:tenant_id/git/blobs
pub fn create_blob(req: Request, _ctx: Context, tenant_id: String) -> Response {
  use body <- wisp.require_json(req)

  case decode_blob_content(body) {
    Error(reason) -> json_helpers.error_response(400, "bad_request", reason)

    Ok(_decoded_content) -> {
      // TODO: wire up storage — levee_storage.ets_create_blob(tables, tenant_id, content)
      let result: Result(types.Blob, types.StorageError) =
        todo as "storage: create blob"

      case result {
        Ok(blob) ->
          json_helpers.json_response(
            201,
            json.object([
              #("sha", json.string(blob.sha)),
              #("url", json.string(blob_url(req, tenant_id, blob.sha))),
            ]),
          )

        Error(_) ->
          json_helpers.error_response(
            500,
            "server_error",
            "Failed to create blob",
          )
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Tree handlers
// ---------------------------------------------------------------------------

/// GET /repos/:tenant_id/git/trees/:sha
pub fn show_tree(
  req: Request,
  _ctx: Context,
  tenant_id: String,
  _sha: String,
) -> Response {
  let query = wisp.get_query(req)
  let _recursive =
    list.key_find(query, "recursive")
    |> result.map(fn(v) { v == "1" })
    |> result.unwrap(False)

  // TODO: wire up storage — levee_storage.ets_get_tree(tables, tenant_id, sha, recursive)
  let result: Result(types.Tree, types.StorageError) =
    todo as "storage: get tree"

  case result {
    Ok(tree) ->
      json_helpers.json_response(200, format_tree_json(req, tenant_id, tree))

    Error(types.NotFound) ->
      json_helpers.error_response(404, "not_found", "Tree not found")

    Error(_) ->
      json_helpers.error_response(500, "server_error", "Storage error")
  }
}

/// POST /repos/:tenant_id/git/trees
pub fn create_tree(req: Request, _ctx: Context, tenant_id: String) -> Response {
  use body <- wisp.require_json(req)

  case decode_tree_entries(body) {
    Error(_) ->
      json_helpers.error_response(400, "bad_request", "Invalid tree entries")

    Ok(_entries) -> {
      // TODO: wire up storage — levee_storage.ets_create_tree(tables, tenant_id, entries)
      let result: Result(types.Tree, types.StorageError) =
        todo as "storage: create tree"

      case result {
        Ok(tree) ->
          json_helpers.json_response(
            201,
            format_tree_json(req, tenant_id, tree),
          )

        Error(_) ->
          json_helpers.error_response(
            500,
            "server_error",
            "Failed to create tree",
          )
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Commit handlers
// ---------------------------------------------------------------------------

/// GET /repos/:tenant_id/git/commits/:sha
pub fn show_commit(
  req: Request,
  _ctx: Context,
  tenant_id: String,
  _sha: String,
) -> Response {
  // TODO: wire up storage — levee_storage.ets_get_commit(tables, tenant_id, sha)
  let result: Result(types.Commit, types.StorageError) =
    todo as "storage: get commit"

  case result {
    Ok(commit) ->
      json_helpers.json_response(
        200,
        format_commit_json(req, tenant_id, commit),
      )

    Error(types.NotFound) ->
      json_helpers.error_response(404, "not_found", "Commit not found")

    Error(_) ->
      json_helpers.error_response(500, "server_error", "Storage error")
  }
}

/// POST /repos/:tenant_id/git/commits
pub fn create_commit(req: Request, _ctx: Context, tenant_id: String) -> Response {
  use body <- wisp.require_json(req)

  case decode_commit_params(body) {
    Error(_) ->
      json_helpers.error_response(
        400,
        "bad_request",
        "Invalid commit parameters",
      )

    Ok(_params) -> {
      // TODO: wire up storage — levee_storage.ets_create_commit(tables, ...)
      let result: Result(types.Commit, types.StorageError) =
        todo as "storage: create commit"

      case result {
        Ok(commit) ->
          json_helpers.json_response(
            201,
            format_commit_json(req, tenant_id, commit),
          )

        Error(_) ->
          json_helpers.error_response(
            500,
            "server_error",
            "Failed to create commit",
          )
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Ref handlers
// ---------------------------------------------------------------------------

/// GET /repos/:tenant_id/git/refs
pub fn list_refs(req: Request, _ctx: Context, tenant_id: String) -> Response {
  // TODO: wire up storage — levee_storage.ets_list_refs(tables, tenant_id)
  let result: Result(List(types.Ref), types.StorageError) =
    todo as "storage: list refs"

  case result {
    Ok(refs) -> {
      let formatted =
        refs
        |> list.map(fn(ref) { format_ref_json(req, tenant_id, ref) })
        |> json.preprocessed_array
      json_helpers.json_response(200, formatted)
    }

    Error(_) ->
      json_helpers.error_response(500, "server_error", "Storage error")
  }
}

/// GET /repos/:tenant_id/git/refs/*path
pub fn show_ref(
  req: Request,
  _ctx: Context,
  tenant_id: String,
  ref_segments: List(String),
) -> Response {
  let _ref_path = build_ref_path(ref_segments)

  // TODO: wire up storage — levee_storage.ets_get_ref(tables, tenant_id, ref_path)
  let result: Result(types.Ref, types.StorageError) = todo as "storage: get ref"

  case result {
    Ok(ref) ->
      json_helpers.json_response(200, format_ref_json(req, tenant_id, ref))

    Error(types.NotFound) ->
      json_helpers.error_response(404, "not_found", "Reference not found")

    Error(_) ->
      json_helpers.error_response(500, "server_error", "Storage error")
  }
}

/// POST /repos/:tenant_id/git/refs
pub fn create_ref(req: Request, _ctx: Context, tenant_id: String) -> Response {
  use body <- wisp.require_json(req)

  case decode_ref_params(body) {
    Error(_) ->
      json_helpers.error_response(400, "bad_request", "Missing ref or sha")

    Ok(#(_ref_path, _sha)) -> {
      // TODO: wire up storage — levee_storage.ets_create_ref(tables, tenant_id, ref_path, sha)
      let result: Result(types.Ref, types.StorageError) =
        todo as "storage: create ref"

      case result {
        Ok(ref) ->
          json_helpers.json_response(201, format_ref_json(req, tenant_id, ref))

        Error(types.AlreadyExists) ->
          json_helpers.error_response(
            409,
            "conflict",
            "Reference already exists",
          )

        Error(_) ->
          json_helpers.error_response(
            400,
            "bad_request",
            "Failed to create reference",
          )
      }
    }
  }
}

/// PATCH /repos/:tenant_id/git/refs/*path
pub fn update_ref(
  req: Request,
  _ctx: Context,
  tenant_id: String,
  ref_segments: List(String),
) -> Response {
  use body <- wisp.require_json(req)

  let _ref_path = build_ref_path(ref_segments)

  case decode_sha(body) {
    Error(_) -> json_helpers.error_response(400, "bad_request", "Missing sha")

    Ok(_sha) -> {
      // TODO: wire up storage — levee_storage.ets_update_ref(tables, tenant_id, ref_path, sha)
      let result: Result(types.Ref, types.StorageError) =
        todo as "storage: update ref"

      case result {
        Ok(ref) ->
          json_helpers.json_response(200, format_ref_json(req, tenant_id, ref))

        Error(types.NotFound) ->
          json_helpers.error_response(404, "not_found", "Reference not found")

        Error(_) ->
          json_helpers.error_response(
            400,
            "bad_request",
            "Failed to update reference",
          )
      }
    }
  }
}

// ---------------------------------------------------------------------------
// JSON formatting helpers
// ---------------------------------------------------------------------------

fn format_tree_json(
  req: Request,
  tenant_id: String,
  tree: types.Tree,
) -> json.Json {
  let formatted_entries =
    tree.tree
    |> list.map(fn(entry) {
      let entry_url = case entry.entry_type {
        "blob" -> blob_url(req, tenant_id, entry.sha)
        "tree" -> tree_url(req, tenant_id, entry.sha)
        _ -> ""
      }

      json.object([
        #("path", json.string(entry.path)),
        #("mode", json.string(entry.mode)),
        #("sha", json.string(entry.sha)),
        #("type", json.string(entry.entry_type)),
        #("url", json.string(entry_url)),
      ])
    })
    |> json.preprocessed_array

  json.object([
    #("sha", json.string(tree.sha)),
    #("url", json.string(tree_url(req, tenant_id, tree.sha))),
    #("tree", formatted_entries),
  ])
}

fn format_commit_json(
  req: Request,
  tenant_id: String,
  commit: types.Commit,
) -> json.Json {
  let parent_objs =
    commit.parents
    |> list.map(fn(parent_sha) {
      json.object([
        #("sha", json.string(parent_sha)),
        #("url", json.string(commit_url(req, tenant_id, parent_sha))),
      ])
    })
    |> json.preprocessed_array

  let message_value = case commit.message {
    Some(msg) -> json.string(msg)
    None -> json.null()
  }

  // author/committer are Dynamic — pass through as null for now.
  // When storage is wired up, these will be proper JSON objects.
  json.object([
    #("sha", json.string(commit.sha)),
    #(
      "tree",
      json.object([
        #("sha", json.string(commit.tree)),
        #("url", json.string(tree_url(req, tenant_id, commit.tree))),
      ]),
    ),
    #("parents", parent_objs),
    #("message", message_value),
    #("author", json.null()),
    #("committer", json.null()),
    #("url", json.string(commit_url(req, tenant_id, commit.sha))),
  ])
}

fn format_ref_json(req: Request, tenant_id: String, ref: types.Ref) -> json.Json {
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

// ---------------------------------------------------------------------------
// URL building helpers
// ---------------------------------------------------------------------------

fn base_url(req: Request) -> String {
  let scheme = case request.get_header(req, "x-forwarded-proto") {
    Ok(proto) -> proto
    Error(_) -> "http"
  }

  let host = case request.get_header(req, "host") {
    Ok(h) -> h
    Error(_) -> "localhost"
  }

  scheme <> "://" <> host
}

fn blob_url(req: Request, tenant_id: String, sha: String) -> String {
  base_url(req) <> "/repos/" <> tenant_id <> "/git/blobs/" <> sha
}

fn tree_url(req: Request, tenant_id: String, sha: String) -> String {
  base_url(req) <> "/repos/" <> tenant_id <> "/git/trees/" <> sha
}

fn commit_url(req: Request, tenant_id: String, sha: String) -> String {
  base_url(req) <> "/repos/" <> tenant_id <> "/git/commits/" <> sha
}

fn ref_url(req: Request, tenant_id: String, ref_path: String) -> String {
  // Remove "refs/" prefix for URL
  let path = case string.starts_with(ref_path, "refs/") {
    True -> string.drop_start(ref_path, 5)
    False -> ref_path
  }

  base_url(req) <> "/repos/" <> tenant_id <> "/git/refs/" <> path
}

// ---------------------------------------------------------------------------
// Request body decoding helpers
// ---------------------------------------------------------------------------

/// Decode blob content from request body.
/// Supports base64-encoded content and raw string content.
fn decode_blob_content(body: Dynamic) -> Result(BitArray, String) {
  let content_result = decode.run(body, decode.at(["content"], decode.string))

  let encoding_result = decode.run(body, decode.at(["encoding"], decode.string))

  case content_result {
    Error(_) -> Error("Missing or invalid content")
    Ok(content) ->
      case encoding_result {
        Ok("base64") ->
          case bit_array.base64_decode(content) {
            Ok(decoded) -> Ok(decoded)
            Error(_) -> Error("Invalid base64 content")
          }
        _ ->
          // Raw string content
          Ok(<<content:utf8>>)
      }
  }
}

/// Decode tree entries from request body.
fn decode_tree_entries(body: Dynamic) -> Result(List(types.TreeEntry), Nil) {
  let entry_decoder = {
    use path <- decode.field("path", decode.string)
    use mode <- decode.optional_field("mode", "100644", decode.string)
    use sha <- decode.field("sha", decode.string)
    use entry_type <- decode.optional_field("type", "blob", decode.string)
    decode.success(types.TreeEntry(
      path: path,
      mode: mode,
      sha: sha,
      entry_type: entry_type,
    ))
  }

  let entries_decoder = decode.at(["tree"], decode.list(entry_decoder))

  decode.run(body, entries_decoder)
  |> result.replace_error(Nil)
}

/// Decoded commit parameters.
pub type CommitParams {
  CommitParams(
    tree: String,
    parents: List(String),
    message: Option(String),
    author: Dynamic,
    committer: Dynamic,
  )
}

/// Decode commit parameters from request body.
fn decode_commit_params(body: Dynamic) -> Result(CommitParams, Nil) {
  let tree_result = decode.run(body, decode.at(["tree"], decode.string))
  let parents_result =
    decode.run(body, decode.at(["parents"], decode.list(decode.string)))

  case tree_result, parents_result {
    Ok(tree_sha), Ok(parents) -> {
      let message = case
        decode.run(body, decode.at(["message"], decode.string))
      {
        Ok(msg) -> Some(msg)
        Error(_) -> None
      }

      // author and committer are opaque JSON objects —
      // pass through as dynamic for storage layer
      let author =
        decode.run(body, decode.at(["author"], decode.dynamic))
        |> result.unwrap(dynamic.nil())

      let committer =
        decode.run(body, decode.at(["committer"], decode.dynamic))
        |> result.unwrap(dynamic.nil())

      Ok(CommitParams(
        tree: tree_sha,
        parents: parents,
        message: message,
        author: author,
        committer: committer,
      ))
    }
    _, _ -> Error(Nil)
  }
}

/// Decode ref creation parameters (ref path and sha).
fn decode_ref_params(body: Dynamic) -> Result(#(String, String), Nil) {
  let decoder = {
    use ref <- decode.field("ref", decode.string)
    use sha <- decode.field("sha", decode.string)
    decode.success(#(ref, sha))
  }

  decode.run(body, decoder)
  |> result.replace_error(Nil)
}

/// Decode just a sha field from request body.
fn decode_sha(body: Dynamic) -> Result(String, Nil) {
  decode.run(body, decode.at(["sha"], decode.string))
  |> result.replace_error(Nil)
}

// ---------------------------------------------------------------------------
// Utility helpers
// ---------------------------------------------------------------------------

/// Build a ref path from URL path segments.
/// E.g., ["heads", "main"] -> "refs/heads/main"
fn build_ref_path(segments: List(String)) -> String {
  "refs/" <> string.join(segments, "/")
}

/// Base64-encode blob content from a Dynamic value.
/// The content field in Blob is Dynamic (BitArray at runtime).
fn encode_blob_content(content: Dynamic) -> String {
  // At runtime, content is a BitArray — decode it
  case decode.run(content, decode.bit_array) {
    Ok(bytes) -> bit_array.base64_encode(bytes, True)
    Error(_) ->
      // Fallback: try as string
      case decode.run(content, decode.string) {
        Ok(s) -> bit_array.base64_encode(<<s:utf8>>, True)
        Error(_) -> ""
      }
  }
}
