//// Interop converters between Gleam storage types and Erlang maps.
////
//// These functions convert between the typed Gleam custom types and
//// atom-keyed Erlang maps consumed by the Elixir session layer.
//// Can be dropped when the Session GenServer is ported to Gleam.

import gleam/dynamic.{type Dynamic}
import levee_storage/types.{
  type Blob, type Commit, type Delta, type Document, type Ref, type Summary,
  type Tree, type TreeEntry,
}

// --- Gleam type → atom-keyed Erlang map ---

@external(erlang, "storage_interop_ffi", "document_to_map")
pub fn document_to_map(doc: Document) -> Dynamic

@external(erlang, "storage_interop_ffi", "delta_to_map")
pub fn delta_to_map(delta: Delta) -> Dynamic

@external(erlang, "storage_interop_ffi", "blob_to_map")
pub fn blob_to_map(blob: Blob) -> Dynamic

@external(erlang, "storage_interop_ffi", "tree_to_map")
pub fn tree_to_map(tree: Tree) -> Dynamic

@external(erlang, "storage_interop_ffi", "tree_entry_to_map")
pub fn tree_entry_to_map(entry: TreeEntry) -> Dynamic

@external(erlang, "storage_interop_ffi", "commit_to_map")
pub fn commit_to_map(commit: Commit) -> Dynamic

@external(erlang, "storage_interop_ffi", "ref_to_map")
pub fn ref_to_map(ref: Ref) -> Dynamic

@external(erlang, "storage_interop_ffi", "summary_to_map")
pub fn summary_to_map(summary: Summary) -> Dynamic

// --- Atom-keyed Erlang map → Gleam type ---

@external(erlang, "storage_interop_ffi", "map_to_delta")
pub fn map_to_delta(map: Dynamic) -> Delta

@external(erlang, "storage_interop_ffi", "map_to_tree_entry")
pub fn map_to_tree_entry(map: Dynamic) -> TreeEntry

@external(erlang, "storage_interop_ffi", "map_to_summary")
pub fn map_to_summary(map: Dynamic) -> Summary
