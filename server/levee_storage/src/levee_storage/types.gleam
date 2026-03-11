//// Storage types for all entity kinds.
////
//// These types mirror the Elixir Behaviour type specs and are used
//// across both ETS and PostgreSQL backends.
////
//// For ETS storage, each entity is stored as a tuple
//// `#(key, value)` in a shelf persistent set (PSet).

import gleam/dynamic.{type Dynamic}
import gleam/option.{type Option}

/// A stored document with metadata.
pub type Document {
  Document(
    id: String,
    tenant_id: String,
    sequence_number: Int,
    created_at: Dynamic,
    updated_at: Dynamic,
  )
}

/// A sequenced delta (operation) record.
pub type Delta {
  Delta(
    sequence_number: Int,
    client_id: Option(String),
    client_sequence_number: Int,
    reference_sequence_number: Int,
    minimum_sequence_number: Int,
    op_type: String,
    contents: Dynamic,
    metadata: Dynamic,
    timestamp: Int,
  )
}

/// A content-addressed blob.
pub type Blob {
  Blob(sha: String, content: Dynamic, size: Int)
}

/// A single entry in a tree object.
pub type TreeEntry {
  TreeEntry(path: String, mode: String, sha: String, entry_type: String)
}

/// A tree object containing entries.
pub type Tree {
  Tree(sha: String, tree: List(TreeEntry))
}

/// A commit object.
pub type Commit {
  Commit(
    sha: String,
    tree: String,
    parents: List(String),
    message: Option(String),
    author: Dynamic,
    committer: Dynamic,
  )
}

/// A Git reference (branch/tag pointer).
pub type Ref {
  Ref(ref: String, sha: String)
}

/// A document summary snapshot.
pub type Summary {
  Summary(
    handle: String,
    tenant_id: String,
    document_id: String,
    sequence_number: Int,
    tree_sha: String,
    commit_sha: Option(String),
    parent_handle: Option(String),
    message: Option(String),
    created_at: Dynamic,
  )
}

/// Storage error variants.
pub type StorageError {
  NotFound
  AlreadyExists
  StorageError(reason: Dynamic)
}
