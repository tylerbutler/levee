//// Levee Storage — Gleam-native storage layer.
////
//// Provides ETS (in-memory) and PostgreSQL backends for document storage.
//// All operations are scoped by tenant_id for multi-tenant isolation.
////
//// This is the main API module. All public functions are re-exported here
//// for use from Elixir via the standard BEAM interop.

import gleam/dynamic.{type Dynamic}
import gleam/option.{type Option}
import levee_storage/ets
import levee_storage/types

// ---------------------------------------------------------------------------
// Re-export types
// ---------------------------------------------------------------------------

pub type Document =
  types.Document

pub type Delta =
  types.Delta

pub type Blob =
  types.Blob

pub type TreeEntry =
  types.TreeEntry

pub type Tree =
  types.Tree

pub type Commit =
  types.Commit

pub type Ref =
  types.Ref

pub type Summary =
  types.Summary

pub type StorageError =
  types.StorageError

pub type Tables =
  ets.Tables

// ---------------------------------------------------------------------------
// ETS backend initialization
// ---------------------------------------------------------------------------

/// Initialize ETS tables. Returns a Tables handle.
pub fn ets_init() -> Tables {
  ets.init()
}

// ---------------------------------------------------------------------------
// Document operations
// ---------------------------------------------------------------------------

pub fn ets_create_document(
  tables: Tables,
  tenant_id: String,
  document_id: String,
  sequence_number: Int,
) -> Result(Document, StorageError) {
  ets.create_document(tables, tenant_id, document_id, sequence_number)
}

pub fn ets_get_document(
  tables: Tables,
  tenant_id: String,
  document_id: String,
) -> Result(Document, StorageError) {
  ets.get_document(tables, tenant_id, document_id)
}

pub fn ets_update_document_sequence(
  tables: Tables,
  tenant_id: String,
  document_id: String,
  sequence_number: Int,
) -> Result(Document, StorageError) {
  ets.update_document_sequence(tables, tenant_id, document_id, sequence_number)
}

// ---------------------------------------------------------------------------
// Delta operations
// ---------------------------------------------------------------------------

pub fn ets_store_delta(
  tables: Tables,
  tenant_id: String,
  document_id: String,
  delta: Delta,
) -> Result(Delta, StorageError) {
  ets.store_delta(tables, tenant_id, document_id, delta)
}

pub fn ets_get_deltas(
  tables: Tables,
  tenant_id: String,
  document_id: String,
  from_sn: Int,
  to_sn: Option(Int),
  limit: Int,
) -> Result(List(Delta), StorageError) {
  ets.get_deltas(tables, tenant_id, document_id, from_sn, to_sn, limit)
}

// ---------------------------------------------------------------------------
// Blob operations
// ---------------------------------------------------------------------------

pub fn ets_create_blob(
  tables: Tables,
  tenant_id: String,
  content: Dynamic,
) -> Result(Blob, StorageError) {
  ets.create_blob(tables, tenant_id, content)
}

pub fn ets_get_blob(
  tables: Tables,
  tenant_id: String,
  sha: String,
) -> Result(Blob, StorageError) {
  ets.get_blob(tables, tenant_id, sha)
}

// ---------------------------------------------------------------------------
// Tree operations
// ---------------------------------------------------------------------------

pub fn ets_create_tree(
  tables: Tables,
  tenant_id: String,
  entries: List(TreeEntry),
) -> Result(Tree, StorageError) {
  ets.create_tree(tables, tenant_id, entries)
}

pub fn ets_get_tree(
  tables: Tables,
  tenant_id: String,
  sha: String,
  recursive: Bool,
) -> Result(Tree, StorageError) {
  ets.get_tree(tables, tenant_id, sha, recursive)
}

// ---------------------------------------------------------------------------
// Commit operations
// ---------------------------------------------------------------------------

pub fn ets_create_commit(
  tables: Tables,
  tenant_id: String,
  tree_sha: String,
  parents: List(String),
  message: Option(String),
  author: Dynamic,
  committer: Dynamic,
) -> Result(Commit, StorageError) {
  ets.create_commit(
    tables,
    tenant_id,
    tree_sha,
    parents,
    message,
    author,
    committer,
  )
}

pub fn ets_get_commit(
  tables: Tables,
  tenant_id: String,
  sha: String,
) -> Result(Commit, StorageError) {
  ets.get_commit(tables, tenant_id, sha)
}

// ---------------------------------------------------------------------------
// Reference operations
// ---------------------------------------------------------------------------

pub fn ets_create_ref(
  tables: Tables,
  tenant_id: String,
  ref_path: String,
  sha: String,
) -> Result(Ref, StorageError) {
  ets.create_ref(tables, tenant_id, ref_path, sha)
}

pub fn ets_get_ref(
  tables: Tables,
  tenant_id: String,
  ref_path: String,
) -> Result(Ref, StorageError) {
  ets.get_ref(tables, tenant_id, ref_path)
}

pub fn ets_list_refs(
  tables: Tables,
  tenant_id: String,
) -> Result(List(Ref), StorageError) {
  ets.list_refs(tables, tenant_id)
}

pub fn ets_update_ref(
  tables: Tables,
  tenant_id: String,
  ref_path: String,
  sha: String,
) -> Result(Ref, StorageError) {
  ets.update_ref(tables, tenant_id, ref_path, sha)
}

// ---------------------------------------------------------------------------
// Summary operations
// ---------------------------------------------------------------------------

pub fn ets_store_summary(
  tables: Tables,
  tenant_id: String,
  document_id: String,
  summary: Summary,
) -> Result(Summary, StorageError) {
  ets.store_summary(tables, tenant_id, document_id, summary)
}

pub fn ets_get_summary(
  tables: Tables,
  tenant_id: String,
  document_id: String,
  handle: String,
) -> Result(Summary, StorageError) {
  ets.get_summary(tables, tenant_id, document_id, handle)
}

pub fn ets_get_latest_summary(
  tables: Tables,
  tenant_id: String,
  document_id: String,
) -> Result(Summary, StorageError) {
  ets.get_latest_summary(tables, tenant_id, document_id)
}

pub fn ets_list_summaries(
  tables: Tables,
  tenant_id: String,
  document_id: String,
  from_sn: Int,
  limit: Int,
) -> Result(List(Summary), StorageError) {
  ets.list_summaries(tables, tenant_id, document_id, from_sn, limit)
}
