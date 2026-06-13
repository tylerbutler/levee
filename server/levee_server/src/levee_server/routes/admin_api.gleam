import envoy
import gleam/crypto
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/http
import gleam/http/request
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import levee_server/storage
import levee_storage
import levee_storage/types.{
  type Blob, type Commit, type Delta, type Document, type Ref, type Summary,
  type Tree, NotFound,
}
import session
import session_store
import wisp

@external(erlang, "levee_server_ffi", "get_auth_store")
fn ffi_get_auth_store() -> Result(Subject(session_store.Message), Nil)

@external(erlang, "levee_server_ffi", "list_tenants_with_names")
fn ffi_list_tenants_with_names() -> List(#(String, String))

@external(erlang, "levee_server_ffi", "create_tenant")
fn ffi_create_tenant(
  name: String,
) -> Result(#(String, String, String, String), Nil)

@external(erlang, "levee_server_ffi", "get_tenant")
fn ffi_get_tenant(id: String) -> Result(#(String, String), Nil)

@external(erlang, "levee_server_ffi", "get_tenant_secrets")
fn ffi_get_tenant_secrets(id: String) -> Result(#(String, String), Nil)

@external(erlang, "levee_server_ffi", "regenerate_tenant_secret")
fn ffi_regenerate_tenant_secret(id: String, slot: Int) -> Result(String, Nil)

@external(erlang, "levee_server_ffi", "delete_tenant")
fn ffi_delete_tenant(id: String) -> Bool

@external(erlang, "levee_server_ffi", "tenant_exists")
fn ffi_tenant_exists(id: String) -> Bool

@external(erlang, "levee_server_ffi", "session_alive")
fn session_alive(tenant_id: String, document_id: String) -> Bool

type CreateTenantInput {
  CreateTenantInput(name: String)
}

pub fn handle(req: wisp.Request) -> Result(wisp.Response, Nil) {
  case req.method, wisp.path_segments(req) {
    http.Get, ["api", "admin", "tenants"] -> admin_key_route(req, list_tenants)
    http.Post, ["api", "admin", "tenants"] ->
      admin_key_route(req, fn() { create_tenant(req) })
    http.Get, ["api", "admin", "tenants", id] ->
      admin_key_route(req, fn() { show_tenant(id) })
    http.Delete, ["api", "admin", "tenants", id] ->
      admin_key_route(req, fn() { delete_tenant(id) })
    http.Post, ["api", "admin", "tenants", id, "secrets", slot] ->
      admin_key_route(req, fn() { regenerate_secret(id, slot) })

    http.Get, ["api", "tenants"] | http.Get, ["api", "tenants", ""] ->
      admin_session_route(req, list_tenants)
    http.Post, ["api", "tenants"] | http.Post, ["api", "tenants", ""] ->
      admin_session_route(req, fn() { create_tenant(req) })
    http.Get, ["api", "tenants", tenant_id, "documents"] ->
      admin_session_route(req, fn() { documents_index(tenant_id) })
    http.Get, ["api", "tenants", tenant_id, "documents", id] ->
      admin_session_route(req, fn() { document_show(tenant_id, id) })
    http.Get, ["api", "tenants", tenant_id, "documents", id, "deltas"] ->
      admin_session_route(req, fn() { deltas(req, tenant_id, id) })
    http.Get, ["api", "tenants", tenant_id, "documents", id, "summaries"] ->
      admin_session_route(req, fn() { summaries(req, tenant_id, id) })
    http.Get, ["api", "tenants", tenant_id, "refs"] ->
      admin_session_route(req, fn() { refs(tenant_id) })
    http.Get, ["api", "tenants", tenant_id, "git", "blobs", sha] ->
      admin_session_route(req, fn() { blob(tenant_id, sha) })
    http.Get, ["api", "tenants", tenant_id, "git", "trees", sha] ->
      admin_session_route(req, fn() { tree(req, tenant_id, sha) })
    http.Get, ["api", "tenants", tenant_id, "git", "commits", sha] ->
      admin_session_route(req, fn() { commit(tenant_id, sha) })
    http.Get, ["api", "tenants", id] ->
      admin_session_route(req, fn() { show_tenant(id) })
    http.Delete, ["api", "tenants", id] ->
      admin_session_route(req, fn() { delete_tenant(id) })
    http.Post, ["api", "tenants", id, "secrets", slot] ->
      admin_session_route(req, fn() { regenerate_secret(id, slot) })

    _, _ -> Error(Nil)
  }
}

fn admin_key_route(
  req: wisp.Request,
  next: fn() -> wisp.Response,
) -> Result(wisp.Response, Nil) {
  case verify_admin_key(req) {
    Ok(Nil) -> Ok(next())
    Error(Nil) -> Ok(coded_error("unauthorized", "Invalid admin key", 401))
  }
}

fn verify_admin_key(req: wisp.Request) -> Result(Nil, Nil) {
  use token <- result.try(extract_bearer(req))
  use key <- result.try(
    envoy.get("LEVEE_ADMIN_KEY") |> result.replace_error(Nil),
  )
  case key, crypto.secure_compare(<<token:utf8>>, <<key:utf8>>) {
    "", _ -> Error(Nil)
    _, True -> Ok(Nil)
    _, False -> Error(Nil)
  }
}

fn admin_session_route(
  req: wisp.Request,
  next: fn() -> wisp.Response,
) -> Result(wisp.Response, Nil) {
  case require_admin_session(req) {
    Ok(Nil) -> Ok(next())
    Error(Forbidden) ->
      Ok(coded_error("forbidden", "Admin access required", 403))
    Error(Unauthorized) ->
      Ok(coded_error("unauthorized", "Invalid or expired session", 401))
  }
}

type AdminSessionError {
  Unauthorized
  Forbidden
}

fn require_admin_session(req: wisp.Request) -> Result(Nil, AdminSessionError) {
  use token <- result.try(
    extract_bearer(req) |> result.replace_error(Unauthorized),
  )
  use store <- result.try(
    ffi_get_auth_store() |> result.replace_error(Unauthorized),
  )
  use current_session <- result.try(
    session_store.get_session(store, token, None)
    |> result.replace_error(Unauthorized),
  )
  case session.is_valid(current_session) {
    False -> Error(Unauthorized)
    True -> {
      use current_user <- result.try(
        session_store.get_user(store, current_session.user_id)
        |> result.replace_error(Unauthorized),
      )
      case current_user.is_admin {
        True -> Ok(Nil)
        False -> Error(Forbidden)
      }
    }
  }
}

fn list_tenants() -> wisp.Response {
  ffi_list_tenants_with_names()
  |> json.array(fn(t) {
    let #(id, name) = t
    tenant_info_json(id, name)
  })
  |> fn(tenants) { json.object([#("tenants", tenants)]) }
  |> json_response(200)
}

fn create_tenant(req: wisp.Request) -> wisp.Response {
  use body <- wisp.require_string_body(req)
  case json.parse(body, create_tenant_decoder()) {
    Ok(input) ->
      case ffi_create_tenant(input.name) {
        Ok(t) -> {
          let #(id, name, secret1, secret2) = t
          json.object([
            #("tenant", tenant_with_secrets_json(id, name, secret1, secret2)),
          ])
          |> json_response(201)
        }
        Error(Nil) -> storage_error("tenant_create_failed")
      }
    Error(_) -> coded_error("missing_fields", "Required: name", 422)
  }
}

fn show_tenant(id: String) -> wisp.Response {
  case ffi_get_tenant(id), ffi_get_tenant_secrets(id) {
    Ok(#(_, name)), Ok(#(secret1, secret2)) ->
      json.object([
        #("tenant", tenant_with_secrets_json(id, name, secret1, secret2)),
      ])
      |> json_response(200)
    _, _ -> not_found("Tenant not found")
  }
}

fn regenerate_secret(id: String, slot_string: String) -> wisp.Response {
  case int.parse(slot_string) {
    Ok(slot) if slot == 1 || slot == 2 ->
      case ffi_regenerate_tenant_secret(id, slot) {
        Ok(secret) ->
          json.object([#("secret", json.string(secret))]) |> json_response(200)
        Error(Nil) -> not_found("Tenant not found")
      }
    _ -> coded_error("invalid_slot", "Slot must be 1 or 2", 400)
  }
}

fn delete_tenant(id: String) -> wisp.Response {
  case ffi_tenant_exists(id) {
    True -> {
      let _ = ffi_delete_tenant(id)
      json.object([#("message", json.string("Tenant unregistered"))])
      |> json_response(200)
    }
    False -> not_found("Tenant not found")
  }
}

fn documents_index(tenant_id: String) -> wisp.Response {
  case storage.get_tables() {
    Error(Nil) -> storage_error("storage unavailable")
    Ok(tables) ->
      case levee_storage.ets_list_documents(tables, tenant_id) {
        Ok(documents) ->
          documents
          |> json.array(fn(doc) { document_json(doc, True) })
          |> fn(docs) { json.object([#("documents", docs)]) }
          |> json_response(200)
        Error(reason) -> storage_error(storage.dynamic_to_json(reason))
      }
  }
}

fn document_show(tenant_id: String, id: String) -> wisp.Response {
  case storage.get_tables() {
    Error(Nil) -> storage_error("storage unavailable")
    Ok(tables) ->
      case levee_storage.ets_get_document(tables, tenant_id, id) {
        Ok(doc) ->
          json.object([
            #("document", document_json(doc, True)),
            #("session", json.null()),
          ])
          |> json_response(200)
        Error(NotFound) -> not_found("Document not found")
        Error(_) -> storage_error("storage_error")
      }
  }
}

fn deltas(req: wisp.Request, tenant_id: String, id: String) -> wisp.Response {
  case storage.get_tables() {
    Error(Nil) -> storage_error("storage unavailable")
    Ok(tables) -> {
      let from = query_int(req, "from", -1)
      let to = query_optional_int(req, "to")
      let limit = query_int(req, "limit", 100)
      case
        levee_storage.ets_get_deltas(tables, tenant_id, id, from, to, limit)
      {
        Ok(deltas) ->
          deltas
          |> json.array(delta_json)
          |> fn(items) { json.object([#("deltas", items)]) }
          |> json_response(200)
        Error(_) -> storage_error("storage_error")
      }
    }
  }
}

fn summaries(req: wisp.Request, tenant_id: String, id: String) -> wisp.Response {
  case storage.get_tables() {
    Error(Nil) -> storage_error("storage unavailable")
    Ok(tables) -> {
      let from = query_int(req, "from_sequence_number", 0)
      let limit = query_int(req, "limit", 100)
      case
        levee_storage.ets_list_summaries(tables, tenant_id, id, from, limit)
      {
        Ok(summaries) ->
          summaries
          |> json.array(summary_json)
          |> fn(items) { json.object([#("summaries", items)]) }
          |> json_response(200)
        Error(_) -> storage_error("storage_error")
      }
    }
  }
}

fn refs(tenant_id: String) -> wisp.Response {
  case storage.get_tables() {
    Error(Nil) -> storage_error("storage unavailable")
    Ok(tables) ->
      case levee_storage.ets_list_refs(tables, tenant_id) {
        Ok(refs) ->
          refs
          |> json.array(ref_json)
          |> fn(items) { json.object([#("refs", items)]) }
          |> json_response(200)
        Error(_) -> storage_error("storage_error")
      }
  }
}

fn blob(tenant_id: String, sha: String) -> wisp.Response {
  case storage.get_tables() {
    Error(Nil) -> storage_error("storage unavailable")
    Ok(tables) ->
      case levee_storage.ets_get_blob(tables, tenant_id, sha) {
        Ok(blob) ->
          json.object([#("blob", blob_json(blob))]) |> json_response(200)
        Error(NotFound) -> not_found("Blob not found")
        Error(_) -> storage_error("storage_error")
      }
  }
}

fn tree(req: wisp.Request, tenant_id: String, sha: String) -> wisp.Response {
  case storage.get_tables() {
    Error(Nil) -> storage_error("storage unavailable")
    Ok(tables) -> {
      let recursive =
        query_value(req, "recursive") == Some("1")
        || query_value(req, "recursive") == Some("true")
      case levee_storage.ets_get_tree(tables, tenant_id, sha, recursive) {
        Ok(tree) ->
          json.object([#("tree", tree_json(tree))]) |> json_response(200)
        Error(NotFound) -> not_found("Tree not found")
        Error(_) -> storage_error("storage_error")
      }
    }
  }
}

fn commit(tenant_id: String, sha: String) -> wisp.Response {
  case storage.get_tables() {
    Error(Nil) -> storage_error("storage unavailable")
    Ok(tables) ->
      case levee_storage.ets_get_commit(tables, tenant_id, sha) {
        Ok(commit) ->
          json.object([#("commit", commit_json(commit))]) |> json_response(200)
        Error(NotFound) -> not_found("Commit not found")
        Error(_) -> storage_error("storage_error")
      }
  }
}

fn tenant_info_json(id: String, name: String) -> json.Json {
  json.object([#("id", json.string(id)), #("name", json.string(name))])
}

fn tenant_with_secrets_json(
  id: String,
  name: String,
  secret1: String,
  secret2: String,
) -> json.Json {
  json.object([
    #("id", json.string(id)),
    #("name", json.string(name)),
    #("secret1", json.string(secret1)),
    #("secret2", json.string(secret2)),
  ])
}

fn document_json(doc: Document, include_session: Bool) -> json.Json {
  let fields = [
    #("id", json.string(doc.id)),
    #("tenant_id", json.string(doc.tenant_id)),
    #("sequence_number", json.int(doc.sequence_number)),
    #("created_at", dynamic_json(doc.created_at)),
    #("updated_at", dynamic_json(doc.updated_at)),
  ]
  let fields = case include_session {
    True ->
      list.append(fields, [
        #("session_alive", json.bool(session_alive(doc.tenant_id, doc.id))),
      ])
    False -> fields
  }
  json.object(fields)
}

fn delta_json(delta: Delta) -> json.Json {
  json.object([
    #("sequence_number", json.int(delta.sequence_number)),
    #("client_id", json.nullable(delta.client_id, json.string)),
    #("client_sequence_number", json.int(delta.client_sequence_number)),
    #("reference_sequence_number", json.int(delta.reference_sequence_number)),
    #("minimum_sequence_number", json.int(delta.minimum_sequence_number)),
    #("type", json.string(delta.op_type)),
    #("contents", json.string(safe_json_string(delta.contents))),
    #("metadata", json.string(safe_json_string(delta.metadata))),
    #("timestamp", json.int(delta.timestamp)),
  ])
}

fn summary_json(summary: Summary) -> json.Json {
  json.object([
    #("handle", json.string(summary.handle)),
    #("tenant_id", json.string(summary.tenant_id)),
    #("document_id", json.string(summary.document_id)),
    #("sequence_number", json.int(summary.sequence_number)),
    #("tree_sha", json.string(summary.tree_sha)),
    #("commit_sha", json.nullable(summary.commit_sha, json.string)),
    #("parent_handle", json.nullable(summary.parent_handle, json.string)),
    #("message", json.nullable(summary.message, json.string)),
    #("created_at", dynamic_json(summary.created_at)),
  ])
}

fn ref_json(ref: Ref) -> json.Json {
  json.object([#("ref", json.string(ref.ref)), #("sha", json.string(ref.sha))])
}

fn blob_json(blob: Blob) -> json.Json {
  json.object([
    #("sha", json.string(blob.sha)),
    #("content", dynamic_json(blob.content)),
    #("size", json.int(blob.size)),
  ])
}

fn tree_json(tree: Tree) -> json.Json {
  json.object([
    #("sha", json.string(tree.sha)),
    #(
      "tree",
      json.array(tree.tree, fn(entry) {
        json.object([
          #("path", json.string(entry.path)),
          #("mode", json.string(entry.mode)),
          #("sha", json.string(entry.sha)),
          #("type", json.string(entry.entry_type)),
        ])
      }),
    ),
  ])
}

fn commit_json(commit: Commit) -> json.Json {
  json.object([
    #("sha", json.string(commit.sha)),
    #("tree", json.string(commit.tree)),
    #("parents", json.array(commit.parents, json.string)),
    #("message", json.nullable(commit.message, json.string)),
    #("author", dynamic_json(commit.author)),
    #("committer", dynamic_json(commit.committer)),
  ])
}

fn dynamic_json(value: a) -> json.Json {
  storage.dynamic_to_json(value)
  |> storage.json_fragment
}

fn safe_json_string(value: a) -> String {
  storage.dynamic_to_json(value)
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

fn create_tenant_decoder() -> decode.Decoder(CreateTenantInput) {
  use name <- decode.field("name", decode.string)
  decode.success(CreateTenantInput(name:))
}

fn extract_bearer(req: wisp.Request) -> Result(String, Nil) {
  case request.get_header(req, "authorization") {
    Ok("Bearer " <> token) -> Ok(string.trim(token))
    _ -> Error(Nil)
  }
}

fn not_found(message: String) -> wisp.Response {
  coded_error("not_found", message, 404)
}

fn storage_error(message: String) -> wisp.Response {
  coded_error("storage_error", message, 500)
}

fn coded_error(code: String, message: String, status: Int) -> wisp.Response {
  json.object([
    #(
      "error",
      json.object([
        #("code", json.string(code)),
        #("message", json.string(message)),
      ]),
    ),
  ])
  |> json_response(status)
}

fn json_response(body: json.Json, status: Int) -> wisp.Response {
  body |> json.to_string |> wisp.json_response(status)
}
