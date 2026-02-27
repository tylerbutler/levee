//// ETS-backed in-memory storage backend using bravo.
////
//// Uses bravo USet/OSet for typed ETS access.
//// All operations are scoped by tenant_id for multi-tenant isolation.
//// Data is not persisted across restarts.

import bravo
import bravo/oset.{type OSet}
import bravo/uset.{type USet}
import gleam/bit_array
import gleam/crypto
import gleam/dynamic.{type Dynamic}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string
import levee_storage/types.{
  type Blob, type Commit, type Delta, type Document, type Ref, type StorageError,
  type Summary, type Tree, type TreeEntry, AlreadyExists, Blob, Commit, Document,
  NotFound, Ref, Summary, Tree, TreeEntry,
}

// ---------------------------------------------------------------------------
// Table types
// ---------------------------------------------------------------------------

/// Holds all seven ETS table handles.
pub type Tables {
  Tables(
    documents: USet(#(String, String), Document),
    deltas: OSet(#(String, String, Int), Delta),
    blobs: USet(#(String, String), Blob),
    trees: USet(#(String, String), Tree),
    commits: USet(#(String, String), Commit),
    refs: USet(#(String, String), Ref),
    summaries: OSet(#(String, String, Int), Summary),
  )
}

/// Create all ETS tables. Returns a Tables handle.
pub fn init() -> Tables {
  let assert Ok(documents) =
    uset.new(name: "levee_documents", access: bravo.Public)
  let assert Ok(deltas) = oset.new(name: "levee_deltas", access: bravo.Public)
  let assert Ok(blobs) = uset.new(name: "levee_blobs", access: bravo.Public)
  let assert Ok(trees) = uset.new(name: "levee_trees", access: bravo.Public)
  let assert Ok(commits) = uset.new(name: "levee_commits", access: bravo.Public)
  let assert Ok(refs) = uset.new(name: "levee_refs", access: bravo.Public)
  let assert Ok(summaries) =
    oset.new(name: "levee_summaries", access: bravo.Public)

  Tables(documents:, deltas:, blobs:, trees:, commits:, refs:, summaries:)
}

// ---------------------------------------------------------------------------
// Document operations
// ---------------------------------------------------------------------------

/// Create a new document. Fails if already exists.
pub fn create_document(
  tables: Tables,
  tenant_id: String,
  document_id: String,
  sequence_number: Int,
) -> Result(Document, StorageError) {
  let now = utc_now()
  let doc =
    Document(
      id: document_id,
      tenant_id: tenant_id,
      sequence_number: sequence_number,
      created_at: now,
      updated_at: now,
    )
  let key = #(tenant_id, document_id)
  case uset.insert_new(into: tables.documents, key: key, value: doc) {
    Ok(_) -> Ok(doc)
    Error(_) -> Error(AlreadyExists)
  }
}

/// Get a document by tenant and document ID.
pub fn get_document(
  tables: Tables,
  tenant_id: String,
  document_id: String,
) -> Result(Document, StorageError) {
  let key = #(tenant_id, document_id)
  case uset.lookup(from: tables.documents, at: key) {
    Ok(doc) -> Ok(doc)
    Error(_) -> Error(NotFound)
  }
}

/// Update the sequence number of a document.
pub fn update_document_sequence(
  tables: Tables,
  tenant_id: String,
  document_id: String,
  sequence_number: Int,
) -> Result(Document, StorageError) {
  let key = #(tenant_id, document_id)
  case uset.lookup(from: tables.documents, at: key) {
    Ok(doc) -> {
      let updated =
        Document(..doc, sequence_number: sequence_number, updated_at: utc_now())
      let _ = uset.insert(into: tables.documents, key: key, value: updated)
      Ok(updated)
    }
    Error(_) -> Error(NotFound)
  }
}

// ---------------------------------------------------------------------------
// Delta operations
// ---------------------------------------------------------------------------

/// Store a delta for a document.
pub fn store_delta(
  tables: Tables,
  tenant_id: String,
  document_id: String,
  delta: Delta,
) -> Result(Delta, StorageError) {
  let key = #(tenant_id, document_id, delta.sequence_number)
  let _ = oset.insert(into: tables.deltas, key: key, value: delta)
  Ok(delta)
}

/// Get deltas for a document with optional filtering.
pub fn get_deltas(
  tables: Tables,
  tenant_id: String,
  document_id: String,
  from_sn: Int,
  to_sn: Option(Int),
  limit: Int,
) -> Result(List(Delta), StorageError) {
  let effective_limit = case limit > 2000 || limit < 1 {
    True -> 2000
    False -> limit
  }

  // OSet tab2list returns entries sorted by key
  let deltas =
    oset.tab2list(from: tables.deltas)
    |> result.unwrap([])
    |> list.filter_map(fn(entry) {
      let #(#(tid, did, sn), delta) = entry
      case tid == tenant_id && did == document_id && sn > from_sn {
        True ->
          case to_sn {
            None -> Ok(delta)
            Some(to) ->
              case sn < to {
                True -> Ok(delta)
                False -> Error(Nil)
              }
          }
        False -> Error(Nil)
      }
    })
    |> list.take(effective_limit)

  Ok(deltas)
}

// ---------------------------------------------------------------------------
// Blob operations
// ---------------------------------------------------------------------------

/// Create a blob (content-addressed by SHA-256).
pub fn create_blob(
  tables: Tables,
  tenant_id: String,
  content: Dynamic,
) -> Result(Blob, StorageError) {
  let sha = compute_sha256(content)
  let size = byte_size(content)
  let blob = Blob(sha: sha, content: content, size: size)
  let key = #(tenant_id, sha)
  let _ = uset.insert(into: tables.blobs, key: key, value: blob)
  Ok(blob)
}

/// Get a blob by SHA.
pub fn get_blob(
  tables: Tables,
  tenant_id: String,
  sha: String,
) -> Result(Blob, StorageError) {
  let key = #(tenant_id, sha)
  case uset.lookup(from: tables.blobs, at: key) {
    Ok(blob) -> Ok(blob)
    Error(_) -> Error(NotFound)
  }
}

// ---------------------------------------------------------------------------
// Tree operations
// ---------------------------------------------------------------------------

/// Create a tree (content-addressed by SHA-256 of serialized entries).
pub fn create_tree(
  tables: Tables,
  tenant_id: String,
  entries: List(TreeEntry),
) -> Result(Tree, StorageError) {
  let tree_content = json_encode_entries(entries)
  let sha = compute_sha256(tree_content)
  let tree = Tree(sha: sha, tree: entries)
  let key = #(tenant_id, sha)
  let _ = uset.insert(into: tables.trees, key: key, value: tree)
  Ok(tree)
}

/// Get a tree by SHA, optionally expanding subtrees recursively.
pub fn get_tree(
  tables: Tables,
  tenant_id: String,
  sha: String,
  recursive: Bool,
) -> Result(Tree, StorageError) {
  let key = #(tenant_id, sha)
  case uset.lookup(from: tables.trees, at: key) {
    Ok(tree) ->
      case recursive {
        True -> Ok(expand_tree_recursive(tables, tenant_id, tree))
        False -> Ok(tree)
      }
    Error(_) -> Error(NotFound)
  }
}

fn expand_tree_recursive(tables: Tables, tenant_id: String, tree: Tree) -> Tree {
  let expanded =
    list.flat_map(tree.tree, fn(entry) {
      case entry.entry_type {
        "tree" ->
          case get_tree(tables, tenant_id, entry.sha, True) {
            Ok(subtree) ->
              list.map(subtree.tree, fn(sub) {
                TreeEntry(..sub, path: entry.path <> "/" <> sub.path)
              })
            Error(_) -> [entry]
          }
        _ -> [entry]
      }
    })
  Tree(..tree, tree: expanded)
}

// ---------------------------------------------------------------------------
// Commit operations
// ---------------------------------------------------------------------------

/// Create a commit (content-addressed by SHA-256).
pub fn create_commit(
  tables: Tables,
  tenant_id: String,
  tree_sha: String,
  parents: List(String),
  message: Option(String),
  author: Dynamic,
  committer: Dynamic,
) -> Result(Commit, StorageError) {
  let commit_map =
    json.object([
      #("tree", json.string(tree_sha)),
      #("parents", json.array(parents, json.string)),
      #("message", json.nullable(message, json.string)),
      #("author", json_from_dynamic(author)),
    ])
  let commit_content = json.to_string(commit_map)
  let sha = compute_sha256(commit_content)
  let commit =
    Commit(
      sha: sha,
      tree: tree_sha,
      parents: parents,
      message: message,
      author: author,
      committer: committer,
    )
  let key = #(tenant_id, sha)
  let _ = uset.insert(into: tables.commits, key: key, value: commit)
  Ok(commit)
}

/// Get a commit by SHA.
pub fn get_commit(
  tables: Tables,
  tenant_id: String,
  sha: String,
) -> Result(Commit, StorageError) {
  let key = #(tenant_id, sha)
  case uset.lookup(from: tables.commits, at: key) {
    Ok(commit) -> Ok(commit)
    Error(_) -> Error(NotFound)
  }
}

// ---------------------------------------------------------------------------
// Reference operations
// ---------------------------------------------------------------------------

/// Create a new ref. Fails if already exists.
pub fn create_ref(
  tables: Tables,
  tenant_id: String,
  ref_path: String,
  sha: String,
) -> Result(Ref, StorageError) {
  let r = Ref(ref: ref_path, sha: sha)
  let key = #(tenant_id, ref_path)
  case uset.insert_new(into: tables.refs, key: key, value: r) {
    Ok(_) -> Ok(r)
    Error(_) -> Error(AlreadyExists)
  }
}

/// Get a ref by path.
pub fn get_ref(
  tables: Tables,
  tenant_id: String,
  ref_path: String,
) -> Result(Ref, StorageError) {
  let key = #(tenant_id, ref_path)
  case uset.lookup(from: tables.refs, at: key) {
    Ok(r) -> Ok(r)
    Error(_) -> Error(NotFound)
  }
}

/// List all refs for a tenant.
pub fn list_refs(
  tables: Tables,
  tenant_id: String,
) -> Result(List(Ref), StorageError) {
  let refs =
    uset.tab2list(from: tables.refs)
    |> result.unwrap([])
    |> list.filter_map(fn(entry) {
      let #(#(tid, _), r) = entry
      case tid == tenant_id {
        True -> Ok(r)
        False -> Error(Nil)
      }
    })
  Ok(refs)
}

/// Update an existing ref's SHA. Fails if not found.
pub fn update_ref(
  tables: Tables,
  tenant_id: String,
  ref_path: String,
  sha: String,
) -> Result(Ref, StorageError) {
  let key = #(tenant_id, ref_path)
  case uset.lookup(from: tables.refs, at: key) {
    Ok(_) -> {
      let updated = Ref(ref: ref_path, sha: sha)
      let _ = uset.insert(into: tables.refs, key: key, value: updated)
      Ok(updated)
    }
    Error(_) -> Error(NotFound)
  }
}

// ---------------------------------------------------------------------------
// Summary operations
// ---------------------------------------------------------------------------

/// Store a summary for a document.
pub fn store_summary(
  tables: Tables,
  tenant_id: String,
  document_id: String,
  summary: Summary,
) -> Result(Summary, StorageError) {
  let stored =
    Summary(
      ..summary,
      tenant_id: tenant_id,
      document_id: document_id,
      created_at: case dynamic.classify(summary.created_at) {
        "Nil" -> coerce(utc_now())
        _ -> summary.created_at
      },
    )
  let key = #(tenant_id, document_id, summary.sequence_number)
  let _ = oset.insert(into: tables.summaries, key: key, value: stored)

  // Update document with latest summary info
  update_document_latest_summary(tables, tenant_id, document_id, stored)

  Ok(stored)
}

/// Get a summary by handle.
pub fn get_summary(
  tables: Tables,
  tenant_id: String,
  document_id: String,
  handle: String,
) -> Result(Summary, StorageError) {
  let found =
    oset.tab2list(from: tables.summaries)
    |> result.unwrap([])
    |> list.find(fn(entry: #(#(String, String, Int), Summary)) {
      let #(#(tid, did, _), s) = entry
      tid == tenant_id && did == document_id && s.handle == handle
    })
  case found {
    Ok(#(_, summary)) -> Ok(summary)
    Error(_) -> Error(NotFound)
  }
}

/// Get the latest summary for a document.
pub fn get_latest_summary(
  tables: Tables,
  tenant_id: String,
  document_id: String,
) -> Result(Summary, StorageError) {
  let matching =
    oset.tab2list(from: tables.summaries)
    |> result.unwrap([])
    |> list.filter_map(fn(entry: #(#(String, String, Int), Summary)) {
      let #(#(tid, did, sn), s) = entry
      case tid == tenant_id && did == document_id {
        True -> Ok(#(sn, s))
        False -> Error(Nil)
      }
    })
  case matching {
    [] -> Error(NotFound)
    pairs -> {
      let assert Ok(best) =
        list.reduce(pairs, fn(acc, pair) {
          case pair.0 > acc.0 {
            True -> pair
            False -> acc
          }
        })
      Ok(best.1)
    }
  }
}

/// List summaries for a document with optional filtering.
pub fn list_summaries(
  tables: Tables,
  tenant_id: String,
  document_id: String,
  from_sn: Int,
  limit: Int,
) -> Result(List(Summary), StorageError) {
  let summaries =
    oset.tab2list(from: tables.summaries)
    |> result.unwrap([])
    |> list.filter_map(fn(entry: #(#(String, String, Int), Summary)) {
      let #(#(tid, did, sn), s) = entry
      case tid == tenant_id && did == document_id && sn >= from_sn {
        True -> Ok(s)
        False -> Error(Nil)
      }
    })
    |> list.sort(fn(a: Summary, b: Summary) {
      int_compare(a.sequence_number, b.sequence_number)
    })
    |> list.take(limit)
  Ok(summaries)
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

fn update_document_latest_summary(
  tables: Tables,
  tenant_id: String,
  document_id: String,
  _summary: Summary,
) -> Nil {
  let key = #(tenant_id, document_id)
  case uset.lookup(from: tables.documents, at: key) {
    Ok(doc) -> {
      let updated = Document(..doc, updated_at: coerce(utc_now()))
      let _ = uset.insert(into: tables.documents, key: key, value: updated)
      Nil
    }
    Error(_) -> Nil
  }
}

fn compute_sha256(content: a) -> String {
  let bits: BitArray = coerce(content)
  crypto.hash(crypto.Sha256, bits)
  |> bit_array.base16_encode()
  |> string.lowercase()
}

fn json_encode_entries(entries: List(TreeEntry)) -> String {
  json.array(entries, fn(e) {
    json.object([
      #("path", json.string(e.path)),
      #("mode", json.string(e.mode)),
      #("sha", json.string(e.sha)),
      #("type", json.string(e.entry_type)),
    ])
  })
  |> json.to_string()
}

fn int_compare(a: Int, b: Int) -> order.Order {
  case a < b {
    True -> order.Lt
    False ->
      case a > b {
        True -> order.Gt
        False -> order.Eq
      }
  }
}

// ---------------------------------------------------------------------------
// FFI helpers (minimal)
// ---------------------------------------------------------------------------

@external(erlang, "erlang", "byte_size")
fn byte_size(binary: a) -> Int

@external(erlang, "Elixir.DateTime", "utc_now")
fn utc_now() -> Dynamic

/// Identity coercion — trusts runtime type is correct.
@external(erlang, "storage_ffi_helpers", "identity")
fn coerce(val: a) -> b

/// Wrap a Dynamic map as a gleam/json.Json value by JSON-encoding it via Jason.
@external(erlang, "storage_ffi_helpers", "json_from_map")
fn json_from_dynamic(val: Dynamic) -> json.Json
