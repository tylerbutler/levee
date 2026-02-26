//// PostgreSQL storage backend using gleam_pgo.
////
//// All operations are scoped by tenant_id for multi-tenant isolation.
//// Currently returns stub errors; will be implemented in Phase 2.

import gleam/dynamic
import gleam/option.{type Option}
import levee_storage/types.{
  type Blob, type Commit, type Delta, type Document, type Ref, type StorageError,
  type Summary, type Tree, type TreeEntry, StorageError,
}

/// Placeholder connection type — will be replaced by pgo.Connection
/// once gleam_pgo is wired up in Phase 2.
pub type Connection =
  dynamic.Dynamic

fn not_implemented() -> Result(a, StorageError) {
  Error(StorageError(dynamic.string("not_implemented")))
}

// ---------------------------------------------------------------------------
// Document operations
// ---------------------------------------------------------------------------

pub fn create_document(
  _conn: Connection,
  _tenant_id: String,
  _document_id: String,
  _sequence_number: Int,
) -> Result(Document, StorageError) {
  not_implemented()
}

pub fn get_document(
  _conn: Connection,
  _tenant_id: String,
  _document_id: String,
) -> Result(Document, StorageError) {
  not_implemented()
}

pub fn update_document_sequence(
  _conn: Connection,
  _tenant_id: String,
  _document_id: String,
  _sequence_number: Int,
) -> Result(Document, StorageError) {
  not_implemented()
}

// ---------------------------------------------------------------------------
// Delta operations
// ---------------------------------------------------------------------------

pub fn store_delta(
  _conn: Connection,
  _tenant_id: String,
  _document_id: String,
  _delta: Delta,
) -> Result(Delta, StorageError) {
  not_implemented()
}

pub fn get_deltas(
  _conn: Connection,
  _tenant_id: String,
  _document_id: String,
  _from_sn: Int,
  _to_sn: Option(Int),
  _limit: Int,
) -> Result(List(Delta), StorageError) {
  not_implemented()
}

// ---------------------------------------------------------------------------
// Blob operations
// ---------------------------------------------------------------------------

pub fn create_blob(
  _conn: Connection,
  _tenant_id: String,
  _content: dynamic.Dynamic,
) -> Result(Blob, StorageError) {
  not_implemented()
}

pub fn get_blob(
  _conn: Connection,
  _tenant_id: String,
  _sha: String,
) -> Result(Blob, StorageError) {
  not_implemented()
}

// ---------------------------------------------------------------------------
// Tree operations
// ---------------------------------------------------------------------------

pub fn create_tree(
  _conn: Connection,
  _tenant_id: String,
  _entries: List(TreeEntry),
) -> Result(Tree, StorageError) {
  not_implemented()
}

pub fn get_tree(
  _conn: Connection,
  _tenant_id: String,
  _sha: String,
  _recursive: Bool,
) -> Result(Tree, StorageError) {
  not_implemented()
}

// ---------------------------------------------------------------------------
// Commit operations
// ---------------------------------------------------------------------------

pub fn create_commit(
  _conn: Connection,
  _tenant_id: String,
  _tree_sha: String,
  _parents: List(String),
  _message: Option(String),
  _author: dynamic.Dynamic,
  _committer: dynamic.Dynamic,
) -> Result(Commit, StorageError) {
  not_implemented()
}

pub fn get_commit(
  _conn: Connection,
  _tenant_id: String,
  _sha: String,
) -> Result(Commit, StorageError) {
  not_implemented()
}

// ---------------------------------------------------------------------------
// Reference operations
// ---------------------------------------------------------------------------

pub fn create_ref(
  _conn: Connection,
  _tenant_id: String,
  _ref_path: String,
  _sha: String,
) -> Result(Ref, StorageError) {
  not_implemented()
}

pub fn get_ref(
  _conn: Connection,
  _tenant_id: String,
  _ref_path: String,
) -> Result(Ref, StorageError) {
  not_implemented()
}

pub fn list_refs(
  _conn: Connection,
  _tenant_id: String,
) -> Result(List(Ref), StorageError) {
  not_implemented()
}

pub fn update_ref(
  _conn: Connection,
  _tenant_id: String,
  _ref_path: String,
  _sha: String,
) -> Result(Ref, StorageError) {
  not_implemented()
}

// ---------------------------------------------------------------------------
// Summary operations
// ---------------------------------------------------------------------------

pub fn store_summary(
  _conn: Connection,
  _tenant_id: String,
  _document_id: String,
  _summary: Summary,
) -> Result(Summary, StorageError) {
  not_implemented()
}

pub fn get_summary(
  _conn: Connection,
  _tenant_id: String,
  _document_id: String,
  _handle: String,
) -> Result(Summary, StorageError) {
  not_implemented()
}

pub fn get_latest_summary(
  _conn: Connection,
  _tenant_id: String,
  _document_id: String,
) -> Result(Summary, StorageError) {
  not_implemented()
}

pub fn list_summaries(
  _conn: Connection,
  _tenant_id: String,
  _document_id: String,
  _from_sn: Int,
  _limit: Int,
) -> Result(List(Summary), StorageError) {
  not_implemented()
}
