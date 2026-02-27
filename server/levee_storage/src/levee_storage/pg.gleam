//// PostgreSQL storage backend using pog.
////
//// All operations are scoped by tenant_id for multi-tenant isolation.
//// Uses parameterized SQL queries via pog (gleam_pgo).

import gleam/bit_array
import gleam/crypto
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import levee_storage/types.{
  type Blob, type Commit, type Delta, type Document, type Ref, type StorageError,
  type Summary, type Tree, type TreeEntry, AlreadyExists, Blob, Commit, Delta,
  Document, NotFound, Ref, StorageError, Summary, Tree, TreeEntry,
}
import pog

pub type Connection =
  pog.Connection

// ---------------------------------------------------------------------------
// Document operations
// ---------------------------------------------------------------------------

pub fn create_document(
  conn: Connection,
  tenant_id: String,
  document_id: String,
  sequence_number: Int,
) -> Result(Document, StorageError) {
  let result =
    pog.query(
      "INSERT INTO documents (tenant_id, id, sequence_number)
       VALUES ($1, $2, $3)
       RETURNING id, tenant_id, sequence_number, created_at, updated_at",
    )
    |> pog.parameter(pog.text(tenant_id))
    |> pog.parameter(pog.text(document_id))
    |> pog.parameter(pog.int(sequence_number))
    |> pog.returning(document_decoder())
    |> pog.execute(conn)

  case result {
    Ok(pog.Returned(_, [doc])) -> Ok(doc)
    Ok(_) -> Error(StorageError(coerce("unexpected result")))
    Error(pog.ConstraintViolated(_, _, _)) -> Error(AlreadyExists)
    Error(err) -> Error(StorageError(coerce(err)))
  }
}

pub fn get_document(
  conn: Connection,
  tenant_id: String,
  document_id: String,
) -> Result(Document, StorageError) {
  let result =
    pog.query(
      "SELECT id, tenant_id, sequence_number, created_at, updated_at
       FROM documents WHERE tenant_id = $1 AND id = $2",
    )
    |> pog.parameter(pog.text(tenant_id))
    |> pog.parameter(pog.text(document_id))
    |> pog.returning(document_decoder())
    |> pog.execute(conn)

  case result {
    Ok(pog.Returned(_, [doc])) -> Ok(doc)
    Ok(pog.Returned(_, [])) -> Error(NotFound)
    Ok(_) -> Error(StorageError(coerce("unexpected result")))
    Error(err) -> Error(StorageError(coerce(err)))
  }
}

pub fn update_document_sequence(
  conn: Connection,
  tenant_id: String,
  document_id: String,
  sequence_number: Int,
) -> Result(Document, StorageError) {
  let result =
    pog.query(
      "UPDATE documents SET sequence_number = $3, updated_at = NOW()
       WHERE tenant_id = $1 AND id = $2
       RETURNING id, tenant_id, sequence_number, created_at, updated_at",
    )
    |> pog.parameter(pog.text(tenant_id))
    |> pog.parameter(pog.text(document_id))
    |> pog.parameter(pog.int(sequence_number))
    |> pog.returning(document_decoder())
    |> pog.execute(conn)

  case result {
    Ok(pog.Returned(_, [doc])) -> Ok(doc)
    Ok(pog.Returned(_, [])) -> Error(NotFound)
    Ok(_) -> Error(StorageError(coerce("unexpected result")))
    Error(err) -> Error(StorageError(coerce(err)))
  }
}

fn document_decoder() -> decode.Decoder(Document) {
  use id <- decode.field(0, decode.string)
  use tid <- decode.field(1, decode.string)
  use sn <- decode.field(2, decode.int)
  use created <- decode.field(3, decode.dynamic)
  use updated <- decode.field(4, decode.dynamic)
  decode.success(Document(
    id:,
    tenant_id: tid,
    sequence_number: sn,
    created_at: pg_timestamp_to_datetime(created),
    updated_at: pg_timestamp_to_datetime(updated),
  ))
}

// ---------------------------------------------------------------------------
// Delta operations
// ---------------------------------------------------------------------------

pub fn store_delta(
  conn: Connection,
  tenant_id: String,
  document_id: String,
  delta: Delta,
) -> Result(Delta, StorageError) {
  let client_id_val = case delta.client_id {
    Some(cid) -> pog.text(cid)
    None -> pog.null()
  }
  let contents_json = dynamic_to_json_string(delta.contents)
  let metadata_json = dynamic_to_json_string(delta.metadata)

  let result =
    pog.query(
      "INSERT INTO deltas (tenant_id, document_id, sequence_number, client_id,
         client_sequence_number, reference_sequence_number, minimum_sequence_number,
         op_type, contents, metadata, timestamp)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9::jsonb, $10::jsonb, $11)
       ON CONFLICT (tenant_id, document_id, sequence_number) DO UPDATE
       SET client_id = EXCLUDED.client_id
       RETURNING sequence_number, client_id, client_sequence_number,
                 reference_sequence_number, minimum_sequence_number,
                 op_type, contents::text, metadata::text, timestamp",
    )
    |> pog.parameter(pog.text(tenant_id))
    |> pog.parameter(pog.text(document_id))
    |> pog.parameter(pog.int(delta.sequence_number))
    |> pog.parameter(client_id_val)
    |> pog.parameter(pog.int(delta.client_sequence_number))
    |> pog.parameter(pog.int(delta.reference_sequence_number))
    |> pog.parameter(pog.int(delta.minimum_sequence_number))
    |> pog.parameter(pog.text(delta.op_type))
    |> pog.parameter(pog.nullable(pog.text, nullable_string(contents_json)))
    |> pog.parameter(pog.nullable(pog.text, nullable_string(metadata_json)))
    |> pog.parameter(pog.int(delta.timestamp))
    |> pog.returning(delta_decoder())
    |> pog.execute(conn)

  case result {
    Ok(pog.Returned(_, [stored])) -> Ok(stored)
    Ok(_) -> Error(StorageError(coerce("unexpected result")))
    Error(err) -> Error(StorageError(coerce(err)))
  }
}

pub fn get_deltas(
  conn: Connection,
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

  let result = case to_sn {
    None ->
      pog.query(
        "SELECT sequence_number, client_id, client_sequence_number,
                reference_sequence_number, minimum_sequence_number,
                op_type, contents::text, metadata::text, timestamp
         FROM deltas WHERE tenant_id = $1 AND document_id = $2
         AND sequence_number > $3
         ORDER BY sequence_number ASC LIMIT $4",
      )
      |> pog.parameter(pog.text(tenant_id))
      |> pog.parameter(pog.text(document_id))
      |> pog.parameter(pog.int(from_sn))
      |> pog.parameter(pog.int(effective_limit))
      |> pog.returning(delta_decoder())
      |> pog.execute(conn)
    Some(to) ->
      pog.query(
        "SELECT sequence_number, client_id, client_sequence_number,
                reference_sequence_number, minimum_sequence_number,
                op_type, contents::text, metadata::text, timestamp
         FROM deltas WHERE tenant_id = $1 AND document_id = $2
         AND sequence_number > $3 AND sequence_number < $4
         ORDER BY sequence_number ASC LIMIT $5",
      )
      |> pog.parameter(pog.text(tenant_id))
      |> pog.parameter(pog.text(document_id))
      |> pog.parameter(pog.int(from_sn))
      |> pog.parameter(pog.int(to))
      |> pog.parameter(pog.int(effective_limit))
      |> pog.returning(delta_decoder())
      |> pog.execute(conn)
  }

  case result {
    Ok(pog.Returned(_, deltas)) -> Ok(deltas)
    Error(err) -> Error(StorageError(coerce(err)))
  }
}

fn delta_decoder() -> decode.Decoder(Delta) {
  use sn <- decode.field(0, decode.int)
  use cid <- decode.field(1, decode.optional(decode.string))
  use csn <- decode.field(2, decode.int)
  use rsn <- decode.field(3, decode.int)
  use msn <- decode.field(4, decode.int)
  use op_type <- decode.field(5, decode.string)
  use contents <- decode.field(6, decode.optional(decode.string))
  use metadata <- decode.field(7, decode.optional(decode.string))
  use ts <- decode.field(8, decode.int)
  decode.success(Delta(
    sequence_number: sn,
    client_id: cid,
    client_sequence_number: csn,
    reference_sequence_number: rsn,
    minimum_sequence_number: msn,
    op_type:,
    contents: coerce(json_string_to_dynamic(coerce(contents))),
    metadata: coerce(json_string_to_dynamic(coerce(metadata))),
    timestamp: ts,
  ))
}

// ---------------------------------------------------------------------------
// Blob operations
// ---------------------------------------------------------------------------

pub fn create_blob(
  conn: Connection,
  tenant_id: String,
  content: Dynamic,
) -> Result(Blob, StorageError) {
  let content_bits: BitArray = coerce(content)
  let sha = compute_sha256(content_bits)
  let size = byte_size(content)

  let _ =
    pog.query(
      "INSERT INTO blobs (tenant_id, sha, content, size)
       VALUES ($1, $2, $3, $4)
       ON CONFLICT (tenant_id, sha) DO NOTHING",
    )
    |> pog.parameter(pog.text(tenant_id))
    |> pog.parameter(pog.text(sha))
    |> pog.parameter(pog.bytea(content_bits))
    |> pog.parameter(pog.int(size))
    |> pog.execute(conn)

  Ok(Blob(sha:, content:, size:))
}

pub fn get_blob(
  conn: Connection,
  tenant_id: String,
  sha: String,
) -> Result(Blob, StorageError) {
  let decoder = {
    use s <- decode.field(0, decode.string)
    use content <- decode.field(1, decode.bit_array)
    use size <- decode.field(2, decode.int)
    decode.success(Blob(sha: s, content: coerce(content), size:))
  }

  let result =
    pog.query(
      "SELECT sha, content, size FROM blobs WHERE tenant_id = $1 AND sha = $2",
    )
    |> pog.parameter(pog.text(tenant_id))
    |> pog.parameter(pog.text(sha))
    |> pog.returning(decoder)
    |> pog.execute(conn)

  case result {
    Ok(pog.Returned(_, [blob])) -> Ok(blob)
    Ok(pog.Returned(_, [])) -> Error(NotFound)
    Ok(_) -> Error(StorageError(coerce("unexpected result")))
    Error(err) -> Error(StorageError(coerce(err)))
  }
}

// ---------------------------------------------------------------------------
// Tree operations
// ---------------------------------------------------------------------------

pub fn create_tree(
  conn: Connection,
  tenant_id: String,
  entries: List(TreeEntry),
) -> Result(Tree, StorageError) {
  let tree_content = json_encode_entries(entries)
  let sha = compute_sha256(tree_content)

  let _ =
    pog.query(
      "INSERT INTO trees (tenant_id, sha) VALUES ($1, $2)
       ON CONFLICT (tenant_id, sha) DO NOTHING",
    )
    |> pog.parameter(pog.text(tenant_id))
    |> pog.parameter(pog.text(sha))
    |> pog.execute(conn)

  list.each(entries, fn(entry) {
    let _ =
      pog.query(
        "INSERT INTO tree_entries (tenant_id, tree_sha, path, mode, sha, entry_type)
         VALUES ($1, $2, $3, $4, $5, $6)
         ON CONFLICT (tenant_id, tree_sha, path) DO NOTHING",
      )
      |> pog.parameter(pog.text(tenant_id))
      |> pog.parameter(pog.text(sha))
      |> pog.parameter(pog.text(entry.path))
      |> pog.parameter(pog.text(entry.mode))
      |> pog.parameter(pog.text(entry.sha))
      |> pog.parameter(pog.text(entry.entry_type))
      |> pog.execute(conn)
  })

  Ok(Tree(sha:, tree: entries))
}

pub fn get_tree(
  conn: Connection,
  tenant_id: String,
  sha: String,
  recursive: Bool,
) -> Result(Tree, StorageError) {
  let tree_check =
    pog.query("SELECT sha FROM trees WHERE tenant_id = $1 AND sha = $2")
    |> pog.parameter(pog.text(tenant_id))
    |> pog.parameter(pog.text(sha))
    |> pog.returning({
      use s <- decode.field(0, decode.string)
      decode.success(s)
    })
    |> pog.execute(conn)

  case tree_check {
    Ok(pog.Returned(_, [])) -> Error(NotFound)
    Error(err) -> Error(StorageError(coerce(err)))
    Ok(_) -> {
      let result =
        pog.query(
          "SELECT path, mode, sha, entry_type FROM tree_entries
           WHERE tenant_id = $1 AND tree_sha = $2",
        )
        |> pog.parameter(pog.text(tenant_id))
        |> pog.parameter(pog.text(sha))
        |> pog.returning(tree_entry_decoder())
        |> pog.execute(conn)

      case result {
        Ok(pog.Returned(_, entries)) -> {
          let tree = Tree(sha:, tree: entries)
          case recursive {
            True -> Ok(expand_tree_recursive(conn, tenant_id, tree))
            False -> Ok(tree)
          }
        }
        Error(err) -> Error(StorageError(coerce(err)))
      }
    }
  }
}

fn expand_tree_recursive(conn: Connection, tenant_id: String, tree: Tree) -> Tree {
  let expanded =
    list.flat_map(tree.tree, fn(entry) {
      case entry.entry_type {
        "tree" ->
          case get_tree(conn, tenant_id, entry.sha, True) {
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

fn tree_entry_decoder() -> decode.Decoder(TreeEntry) {
  use path <- decode.field(0, decode.string)
  use mode <- decode.field(1, decode.string)
  use sha <- decode.field(2, decode.string)
  use entry_type <- decode.field(3, decode.string)
  decode.success(TreeEntry(path:, mode:, sha:, entry_type:))
}

// ---------------------------------------------------------------------------
// Commit operations
// ---------------------------------------------------------------------------

pub fn create_commit(
  conn: Connection,
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

  let author_json = dynamic_to_json_string(author)
  let committer_json = dynamic_to_json_string(committer)
  let message_val = case message {
    Some(m) -> pog.text(m)
    None -> pog.null()
  }

  let _ =
    pog.query(
      "INSERT INTO commits (tenant_id, sha, tree_sha, parents, message, author, committer)
       VALUES ($1, $2, $3, $4, $5, $6::jsonb, $7::jsonb)
       ON CONFLICT (tenant_id, sha) DO NOTHING",
    )
    |> pog.parameter(pog.text(tenant_id))
    |> pog.parameter(pog.text(sha))
    |> pog.parameter(pog.text(tree_sha))
    |> pog.parameter(pog.array(pog.text, parents))
    |> pog.parameter(message_val)
    |> pog.parameter(pog.text(coerce(author_json)))
    |> pog.parameter(pog.text(coerce(committer_json)))
    |> pog.execute(conn)

  Ok(Commit(sha:, tree: tree_sha, parents:, message:, author:, committer:))
}

pub fn get_commit(
  conn: Connection,
  tenant_id: String,
  sha: String,
) -> Result(Commit, StorageError) {
  let decoder = {
    use s <- decode.field(0, decode.string)
    use tree <- decode.field(1, decode.string)
    use parents <- decode.field(2, decode.list(decode.string))
    use message <- decode.field(3, decode.optional(decode.string))
    use author_str <- decode.field(4, decode.string)
    use committer_str <- decode.field(5, decode.string)
    decode.success(Commit(
      sha: s,
      tree:,
      parents:,
      message:,
      author: coerce(json_string_to_dynamic(coerce(author_str))),
      committer: coerce(json_string_to_dynamic(coerce(committer_str))),
    ))
  }

  let result =
    pog.query(
      "SELECT sha, tree_sha, parents, message, author::text, committer::text
       FROM commits WHERE tenant_id = $1 AND sha = $2",
    )
    |> pog.parameter(pog.text(tenant_id))
    |> pog.parameter(pog.text(sha))
    |> pog.returning(decoder)
    |> pog.execute(conn)

  case result {
    Ok(pog.Returned(_, [commit])) -> Ok(commit)
    Ok(pog.Returned(_, [])) -> Error(NotFound)
    Ok(_) -> Error(StorageError(coerce("unexpected result")))
    Error(err) -> Error(StorageError(coerce(err)))
  }
}

// ---------------------------------------------------------------------------
// Reference operations
// ---------------------------------------------------------------------------

pub fn create_ref(
  conn: Connection,
  tenant_id: String,
  ref_path: String,
  sha: String,
) -> Result(Ref, StorageError) {
  let result =
    pog.query(
      "INSERT INTO refs (tenant_id, ref_path, sha) VALUES ($1, $2, $3)
       RETURNING ref_path, sha",
    )
    |> pog.parameter(pog.text(tenant_id))
    |> pog.parameter(pog.text(ref_path))
    |> pog.parameter(pog.text(sha))
    |> pog.returning(ref_decoder())
    |> pog.execute(conn)

  case result {
    Ok(pog.Returned(_, [r])) -> Ok(r)
    Ok(_) -> Error(StorageError(coerce("unexpected result")))
    Error(pog.ConstraintViolated(_, _, _)) -> Error(AlreadyExists)
    Error(err) -> Error(StorageError(coerce(err)))
  }
}

pub fn get_ref(
  conn: Connection,
  tenant_id: String,
  ref_path: String,
) -> Result(Ref, StorageError) {
  let result =
    pog.query(
      "SELECT ref_path, sha FROM refs WHERE tenant_id = $1 AND ref_path = $2",
    )
    |> pog.parameter(pog.text(tenant_id))
    |> pog.parameter(pog.text(ref_path))
    |> pog.returning(ref_decoder())
    |> pog.execute(conn)

  case result {
    Ok(pog.Returned(_, [r])) -> Ok(r)
    Ok(pog.Returned(_, [])) -> Error(NotFound)
    Ok(_) -> Error(StorageError(coerce("unexpected result")))
    Error(err) -> Error(StorageError(coerce(err)))
  }
}

pub fn list_refs(
  conn: Connection,
  tenant_id: String,
) -> Result(List(Ref), StorageError) {
  let result =
    pog.query("SELECT ref_path, sha FROM refs WHERE tenant_id = $1")
    |> pog.parameter(pog.text(tenant_id))
    |> pog.returning(ref_decoder())
    |> pog.execute(conn)

  case result {
    Ok(pog.Returned(_, refs)) -> Ok(refs)
    Error(err) -> Error(StorageError(coerce(err)))
  }
}

pub fn update_ref(
  conn: Connection,
  tenant_id: String,
  ref_path: String,
  sha: String,
) -> Result(Ref, StorageError) {
  let result =
    pog.query(
      "UPDATE refs SET sha = $3 WHERE tenant_id = $1 AND ref_path = $2
       RETURNING ref_path, sha",
    )
    |> pog.parameter(pog.text(tenant_id))
    |> pog.parameter(pog.text(ref_path))
    |> pog.parameter(pog.text(sha))
    |> pog.returning(ref_decoder())
    |> pog.execute(conn)

  case result {
    Ok(pog.Returned(_, [r])) -> Ok(r)
    Ok(pog.Returned(_, [])) -> Error(NotFound)
    Ok(_) -> Error(StorageError(coerce("unexpected result")))
    Error(err) -> Error(StorageError(coerce(err)))
  }
}

fn ref_decoder() -> decode.Decoder(Ref) {
  use ref <- decode.field(0, decode.string)
  use sha <- decode.field(1, decode.string)
  decode.success(Ref(ref:, sha:))
}

// ---------------------------------------------------------------------------
// Summary operations
// ---------------------------------------------------------------------------

pub fn store_summary(
  conn: Connection,
  tenant_id: String,
  document_id: String,
  summary: Summary,
) -> Result(Summary, StorageError) {
  let commit_sha_val = case summary.commit_sha {
    Some(s) -> pog.text(s)
    None -> pog.null()
  }
  let parent_handle_val = case summary.parent_handle {
    Some(s) -> pog.text(s)
    None -> pog.null()
  }
  let message_val = case summary.message {
    Some(s) -> pog.text(s)
    None -> pog.null()
  }

  let result =
    pog.query(
      "INSERT INTO summaries (tenant_id, document_id, handle, sequence_number,
         tree_sha, commit_sha, parent_handle, message)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
       ON CONFLICT (tenant_id, document_id, sequence_number) DO UPDATE
       SET handle = EXCLUDED.handle, tree_sha = EXCLUDED.tree_sha,
           commit_sha = EXCLUDED.commit_sha, parent_handle = EXCLUDED.parent_handle,
           message = EXCLUDED.message
       RETURNING handle, tenant_id, document_id, sequence_number,
                 tree_sha, commit_sha, parent_handle, message, created_at",
    )
    |> pog.parameter(pog.text(tenant_id))
    |> pog.parameter(pog.text(document_id))
    |> pog.parameter(pog.text(summary.handle))
    |> pog.parameter(pog.int(summary.sequence_number))
    |> pog.parameter(pog.text(summary.tree_sha))
    |> pog.parameter(commit_sha_val)
    |> pog.parameter(parent_handle_val)
    |> pog.parameter(message_val)
    |> pog.returning(summary_decoder())
    |> pog.execute(conn)

  case result {
    Ok(pog.Returned(_, [stored])) -> {
      let _ =
        pog.query(
          "UPDATE documents SET updated_at = NOW()
           WHERE tenant_id = $1 AND id = $2",
        )
        |> pog.parameter(pog.text(tenant_id))
        |> pog.parameter(pog.text(document_id))
        |> pog.execute(conn)
      Ok(stored)
    }
    Ok(_) -> Error(StorageError(coerce("unexpected result")))
    Error(err) -> Error(StorageError(coerce(err)))
  }
}

pub fn get_summary(
  conn: Connection,
  tenant_id: String,
  document_id: String,
  handle: String,
) -> Result(Summary, StorageError) {
  let result =
    pog.query(
      "SELECT handle, tenant_id, document_id, sequence_number,
              tree_sha, commit_sha, parent_handle, message, created_at
       FROM summaries WHERE tenant_id = $1 AND document_id = $2 AND handle = $3",
    )
    |> pog.parameter(pog.text(tenant_id))
    |> pog.parameter(pog.text(document_id))
    |> pog.parameter(pog.text(handle))
    |> pog.returning(summary_decoder())
    |> pog.execute(conn)

  case result {
    Ok(pog.Returned(_, [s])) -> Ok(s)
    Ok(pog.Returned(_, [])) -> Error(NotFound)
    Ok(_) -> Error(StorageError(coerce("unexpected result")))
    Error(err) -> Error(StorageError(coerce(err)))
  }
}

pub fn get_latest_summary(
  conn: Connection,
  tenant_id: String,
  document_id: String,
) -> Result(Summary, StorageError) {
  let result =
    pog.query(
      "SELECT handle, tenant_id, document_id, sequence_number,
              tree_sha, commit_sha, parent_handle, message, created_at
       FROM summaries WHERE tenant_id = $1 AND document_id = $2
       ORDER BY sequence_number DESC LIMIT 1",
    )
    |> pog.parameter(pog.text(tenant_id))
    |> pog.parameter(pog.text(document_id))
    |> pog.returning(summary_decoder())
    |> pog.execute(conn)

  case result {
    Ok(pog.Returned(_, [s])) -> Ok(s)
    Ok(pog.Returned(_, [])) -> Error(NotFound)
    Ok(_) -> Error(StorageError(coerce("unexpected result")))
    Error(err) -> Error(StorageError(coerce(err)))
  }
}

pub fn list_summaries(
  conn: Connection,
  tenant_id: String,
  document_id: String,
  from_sn: Int,
  limit: Int,
) -> Result(List(Summary), StorageError) {
  let result =
    pog.query(
      "SELECT handle, tenant_id, document_id, sequence_number,
              tree_sha, commit_sha, parent_handle, message, created_at
       FROM summaries WHERE tenant_id = $1 AND document_id = $2
       AND sequence_number >= $3
       ORDER BY sequence_number ASC LIMIT $4",
    )
    |> pog.parameter(pog.text(tenant_id))
    |> pog.parameter(pog.text(document_id))
    |> pog.parameter(pog.int(from_sn))
    |> pog.parameter(pog.int(limit))
    |> pog.returning(summary_decoder())
    |> pog.execute(conn)

  case result {
    Ok(pog.Returned(_, summaries)) -> Ok(summaries)
    Error(err) -> Error(StorageError(coerce(err)))
  }
}

fn summary_decoder() -> decode.Decoder(Summary) {
  use handle <- decode.field(0, decode.string)
  use tid <- decode.field(1, decode.string)
  use did <- decode.field(2, decode.string)
  use sn <- decode.field(3, decode.int)
  use tree_sha <- decode.field(4, decode.string)
  use commit_sha <- decode.field(5, decode.optional(decode.string))
  use parent_handle <- decode.field(6, decode.optional(decode.string))
  use message <- decode.field(7, decode.optional(decode.string))
  use created_at <- decode.field(8, decode.dynamic)
  decode.success(Summary(
    handle:,
    tenant_id: tid,
    document_id: did,
    sequence_number: sn,
    tree_sha:,
    commit_sha:,
    parent_handle:,
    message:,
    created_at: pg_timestamp_to_datetime(created_at),
  ))
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

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

fn nullable_string(val: Dynamic) -> Option(String) {
  case dynamic.classify(val) {
    "Nil" -> None
    _ -> Some(coerce(val))
  }
}

// ---------------------------------------------------------------------------
// FFI helpers
// ---------------------------------------------------------------------------

@external(erlang, "erlang", "byte_size")
fn byte_size(binary: a) -> Int

@external(erlang, "storage_ffi_helpers", "identity")
fn coerce(val: a) -> b

@external(erlang, "storage_ffi_helpers", "dynamic_to_json_string")
fn dynamic_to_json_string(val: Dynamic) -> Dynamic

@external(erlang, "storage_ffi_helpers", "json_string_to_dynamic")
fn json_string_to_dynamic(val: Dynamic) -> Dynamic

@external(erlang, "storage_ffi_helpers", "pg_timestamp_to_datetime")
fn pg_timestamp_to_datetime(val: Dynamic) -> Dynamic

@external(erlang, "storage_ffi_helpers", "json_from_map")
fn json_from_dynamic(val: Dynamic) -> json.Json
