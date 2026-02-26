//// ETS-based storage backend for Levee.
//// 
//// This is an in-memory storage backend suitable for development and testing.
//// Data is not persisted across restarts.

import gleam/dynamic.{type Dynamic}
import levee_storage.{type StorageError}

/// Maximum deltas returned per request
pub const max_deltas_per_request = 2000

/// Initialize all ETS tables. Must be called once at startup.
@external(erlang, "levee_storage_ets_backend", "init_tables")
pub fn init_tables() -> Nil

/// Create a new document
@external(erlang, "levee_storage_ets_backend", "create_document")
pub fn create_document(
  tenant_id: String,
  document_id: String,
  params: Dynamic,
) -> Result(Dynamic, StorageError)

/// Get a document by tenant and document ID
@external(erlang, "levee_storage_ets_backend", "get_document")
pub fn get_document(
  tenant_id: String,
  document_id: String,
) -> Result(Dynamic, StorageError)

/// Update document sequence number
@external(erlang, "levee_storage_ets_backend", "update_document_sequence")
pub fn update_document_sequence(
  tenant_id: String,
  document_id: String,
  sequence_number: Int,
) -> Result(Dynamic, StorageError)

/// Store a delta
@external(erlang, "levee_storage_ets_backend", "store_delta")
pub fn store_delta(
  tenant_id: String,
  document_id: String,
  delta: Dynamic,
) -> Result(Dynamic, StorageError)

/// Get deltas with filtering options
@external(erlang, "levee_storage_ets_backend", "get_deltas")
pub fn get_deltas(
  tenant_id: String,
  document_id: String,
  opts: Dynamic,
  max_limit: Int,
) -> Result(Dynamic, StorageError)

/// Create a blob from binary content
@external(erlang, "levee_storage_ets_backend", "create_blob")
pub fn create_blob(
  tenant_id: String,
  content: BitArray,
) -> Result(Dynamic, StorageError)

/// Get a blob by SHA
@external(erlang, "levee_storage_ets_backend", "get_blob")
pub fn get_blob(
  tenant_id: String,
  sha: String,
) -> Result(Dynamic, StorageError)

/// Create a tree from entries
@external(erlang, "levee_storage_ets_backend", "create_tree")
pub fn create_tree(
  tenant_id: String,
  entries: Dynamic,
) -> Result(Dynamic, StorageError)

/// Get a tree by SHA, optionally recursive
@external(erlang, "levee_storage_ets_backend", "get_tree")
pub fn get_tree(
  tenant_id: String,
  sha: String,
  recursive: Bool,
) -> Result(Dynamic, StorageError)

/// Create a commit
@external(erlang, "levee_storage_ets_backend", "create_commit")
pub fn create_commit(
  tenant_id: String,
  params: Dynamic,
) -> Result(Dynamic, StorageError)

/// Get a commit by SHA
@external(erlang, "levee_storage_ets_backend", "get_commit")
pub fn get_commit(
  tenant_id: String,
  sha: String,
) -> Result(Dynamic, StorageError)

/// Create a ref
@external(erlang, "levee_storage_ets_backend", "create_ref")
pub fn create_ref(
  tenant_id: String,
  ref_path: String,
  sha: String,
) -> Result(Dynamic, StorageError)

/// Get a ref by path
@external(erlang, "levee_storage_ets_backend", "get_ref")
pub fn get_ref(
  tenant_id: String,
  ref_path: String,
) -> Result(Dynamic, StorageError)

/// List all refs for a tenant
@external(erlang, "levee_storage_ets_backend", "list_refs")
pub fn list_refs(tenant_id: String) -> Result(Dynamic, StorageError)

/// Update a ref's SHA
@external(erlang, "levee_storage_ets_backend", "update_ref")
pub fn update_ref(
  tenant_id: String,
  ref_path: String,
  sha: String,
) -> Result(Dynamic, StorageError)

/// Store a summary
@external(erlang, "levee_storage_ets_backend", "store_summary")
pub fn store_summary(
  tenant_id: String,
  document_id: String,
  summary: Dynamic,
) -> Result(Dynamic, StorageError)

/// Get a summary by handle
@external(erlang, "levee_storage_ets_backend", "get_summary")
pub fn get_summary(
  tenant_id: String,
  document_id: String,
  handle: String,
) -> Result(Dynamic, StorageError)

/// Get the latest summary for a document
@external(erlang, "levee_storage_ets_backend", "get_latest_summary")
pub fn get_latest_summary(
  tenant_id: String,
  document_id: String,
) -> Result(Dynamic, StorageError)

/// List summaries for a document
@external(erlang, "levee_storage_ets_backend", "list_summaries")
pub fn list_summaries(
  tenant_id: String,
  document_id: String,
  from_sequence_number: Int,
  limit: Int,
) -> Result(Dynamic, StorageError)
