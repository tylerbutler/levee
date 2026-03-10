//// Mesa (Mnesia) storage backend scaffold.
////
//// This module defines the backend shape used by the Elixir adapter.
//// Operations are intentionally stubbed while we incrementally port logic from
//// the ETS backend.

import gleam/dynamic.{type Dynamic}
import gleam/option.{type Option}
import levee_storage/types.{
  type Blob, type Commit, type Delta, type Document, type Ref, type StorageError,
  type Summary, type Tree, type TreeEntry, StorageError,
}

pub type Tables {
  Tables
}

pub fn init() -> Tables {
  Tables
}

pub fn create_document(
  _tables: Tables,
  _tenant_id: String,
  _document_id: String,
  _sequence_number: Int,
) -> Result(Document, StorageError) {
  not_implemented()
}

pub fn get_document(
  _tables: Tables,
  _tenant_id: String,
  _document_id: String,
) -> Result(Document, StorageError) {
  not_implemented()
}

pub fn list_documents(
  _tables: Tables,
  _tenant_id: String,
) -> Result(List(Document), StorageError) {
  not_implemented()
}

pub fn update_document_sequence(
  _tables: Tables,
  _tenant_id: String,
  _document_id: String,
  _sequence_number: Int,
) -> Result(Document, StorageError) {
  not_implemented()
}

pub fn store_delta(
  _tables: Tables,
  _tenant_id: String,
  _document_id: String,
  _delta: Delta,
) -> Result(Delta, StorageError) {
  not_implemented()
}

pub fn get_deltas(
  _tables: Tables,
  _tenant_id: String,
  _document_id: String,
  _from_sn: Int,
  _to_sn: Option(Int),
  _limit: Int,
) -> Result(List(Delta), StorageError) {
  not_implemented()
}

pub fn create_blob(
  _tables: Tables,
  _tenant_id: String,
  _content: Dynamic,
) -> Result(Blob, StorageError) {
  not_implemented()
}

pub fn get_blob(
  _tables: Tables,
  _tenant_id: String,
  _sha: String,
) -> Result(Blob, StorageError) {
  not_implemented()
}

pub fn create_tree(
  _tables: Tables,
  _tenant_id: String,
  _entries: List(TreeEntry),
) -> Result(Tree, StorageError) {
  not_implemented()
}

pub fn get_tree(
  _tables: Tables,
  _tenant_id: String,
  _sha: String,
  _recursive: Bool,
) -> Result(Tree, StorageError) {
  not_implemented()
}

pub fn create_commit(
  _tables: Tables,
  _tenant_id: String,
  _tree_sha: String,
  _parents: List(String),
  _message: Option(String),
  _author: Dynamic,
  _committer: Dynamic,
) -> Result(Commit, StorageError) {
  not_implemented()
}

pub fn get_commit(
  _tables: Tables,
  _tenant_id: String,
  _sha: String,
) -> Result(Commit, StorageError) {
  not_implemented()
}

pub fn create_ref(
  _tables: Tables,
  _tenant_id: String,
  _ref_path: String,
  _sha: String,
) -> Result(Ref, StorageError) {
  not_implemented()
}

pub fn get_ref(
  _tables: Tables,
  _tenant_id: String,
  _ref_path: String,
) -> Result(Ref, StorageError) {
  not_implemented()
}

pub fn list_refs(
  _tables: Tables,
  _tenant_id: String,
) -> Result(List(Ref), StorageError) {
  not_implemented()
}

pub fn update_ref(
  _tables: Tables,
  _tenant_id: String,
  _ref_path: String,
  _sha: String,
) -> Result(Ref, StorageError) {
  not_implemented()
}

pub fn store_summary(
  _tables: Tables,
  _tenant_id: String,
  _document_id: String,
  _summary: Summary,
) -> Result(Summary, StorageError) {
  not_implemented()
}

pub fn get_summary(
  _tables: Tables,
  _tenant_id: String,
  _document_id: String,
  _handle: String,
) -> Result(Summary, StorageError) {
  not_implemented()
}

pub fn get_latest_summary(
  _tables: Tables,
  _tenant_id: String,
  _document_id: String,
) -> Result(Summary, StorageError) {
  not_implemented()
}

pub fn list_summaries(
  _tables: Tables,
  _tenant_id: String,
  _document_id: String,
  _from_sn: Int,
  _limit: Int,
) -> Result(List(Summary), StorageError) {
  not_implemented()
}

fn not_implemented() -> Result(a, StorageError) {
  Error(StorageError(coerce("not_implemented")))
}

@external(erlang, "storage_ffi_helpers", "identity")
fn coerce(val: a) -> b
