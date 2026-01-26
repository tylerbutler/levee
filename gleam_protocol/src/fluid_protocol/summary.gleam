/// Summary Protocol types for Fluid Framework
///
/// Summaries capture point-in-time snapshots of document state for efficient loading.
/// The summary tree structure allows for hierarchical representation of document state.

import gleam/dict.{type Dict}
import gleam/option.{type Option}

/// Summary tree node types
pub type SummaryType {
  /// Tree node containing other summary objects
  Tree
  /// Blob containing raw data
  Blob
  /// Attachment reference to externally uploaded blob
  Attachment
}

/// Summary tree structure - the root of a summary
pub type SummaryTree {
  SummaryTree(tree: Dict(String, SummaryObject))
}

/// Individual objects within a summary tree
pub type SummaryObject {
  /// A blob of data (string content)
  SummaryBlob(content: String)
  /// A handle referencing a previous summary's content
  SummaryHandle(handle: String, handle_type: SummaryType)
  /// An attachment reference to an externally uploaded blob
  SummaryAttachment(id: String)
  /// A nested tree node
  SummaryTreeNode(tree: Dict(String, SummaryObject))
}

/// Summary operation submitted by client
pub type SummaryOp {
  SummaryOp(
    /// Reference to the parent summary being built upon
    parent_summary_handle: String,
    /// The new summary tree
    summary_tree: SummaryTree,
    /// Sequence number this summary covers
    sequence_number: Int,
  )
}

/// Contents of a summarize message as submitted by client
pub type SummarizeContents {
  SummarizeContents(
    /// Reference to uploaded summary (commit SHA or tree SHA)
    handle: String,
    /// Summary description/message
    message: String,
    /// Parent summary handles
    parents: List(String),
    /// Current head reference
    head: String,
    /// Additional details
    includes_protocol_tree: Option(Bool),
  )
}

/// Summary acknowledgment - sent when summary is accepted
pub type SummaryAck {
  SummaryAck(
    /// Final summary handle
    handle: String,
    /// Sequence number of the summarize op
    summary_sequence_number: Int,
  )
}

/// Summary negative acknowledgment - sent when summary is rejected
pub type SummaryNack {
  SummaryNack(
    /// Sequence number of the summarize op
    summary_sequence_number: Int,
    /// Error code
    code: Option(Int),
    /// Error message
    message: Option(String),
    /// Retry delay in seconds (if applicable)
    retry_after: Option(Int),
  )
}

/// Pending summary tracking state
pub type PendingSummary {
  PendingSummary(
    /// The client that submitted the summary
    client_id: String,
    /// The summarize contents
    contents: SummarizeContents,
    /// The sequence number assigned to the summarize op
    sequence_number: Int,
    /// Timestamp when received
    timestamp: Int,
  )
}

/// Summary context returned on document open
pub type SummaryContext {
  SummaryContext(
    /// Handle to the latest summary
    handle: String,
    /// Sequence number that the summary covers
    sequence_number: Int,
  )
}

/// Convert SummaryType to string for wire format
pub fn summary_type_to_string(st: SummaryType) -> String {
  case st {
    Tree -> "tree"
    Blob -> "blob"
    Attachment -> "attachment"
  }
}

/// Parse SummaryType from wire format string
pub fn summary_type_from_string(s: String) -> Result(SummaryType, Nil) {
  case s {
    "tree" -> Ok(Tree)
    "blob" -> Ok(Blob)
    "attachment" -> Ok(Attachment)
    _ -> Error(Nil)
  }
}

/// Convert SummaryType to numeric type code (for ISummaryTree interface)
pub fn summary_type_to_code(st: SummaryType) -> Int {
  case st {
    Tree -> 1
    Blob -> 2
    Attachment -> 4
  }
}

/// Parse SummaryType from numeric type code
pub fn summary_type_from_code(code: Int) -> Result(SummaryType, Nil) {
  case code {
    1 -> Ok(Tree)
    2 -> Ok(Blob)
    4 -> Ok(Attachment)
    _ -> Error(Nil)
  }
}

/// Create an empty summary tree
pub fn empty_summary_tree() -> SummaryTree {
  SummaryTree(tree: dict.new())
}

/// Create a summary tree with entries
pub fn new_summary_tree(entries: List(#(String, SummaryObject))) -> SummaryTree {
  SummaryTree(tree: dict.from_list(entries))
}

/// Add an entry to a summary tree
pub fn add_to_summary_tree(
  summary: SummaryTree,
  path: String,
  object: SummaryObject,
) -> SummaryTree {
  SummaryTree(tree: dict.insert(summary.tree, path, object))
}

/// Get an entry from a summary tree
pub fn get_from_summary_tree(
  summary: SummaryTree,
  path: String,
) -> Result(SummaryObject, Nil) {
  dict.get(summary.tree, path)
}

/// Create a SummaryAck
pub fn create_summary_ack(handle: String, sequence_number: Int) -> SummaryAck {
  SummaryAck(handle: handle, summary_sequence_number: sequence_number)
}

/// Create a SummaryNack with error message
pub fn create_summary_nack(
  sequence_number: Int,
  code: Option(Int),
  message: Option(String),
) -> SummaryNack {
  SummaryNack(
    summary_sequence_number: sequence_number,
    code: code,
    message: message,
    retry_after: option.None,
  )
}

/// Create a SummaryNack with retry information
pub fn create_summary_nack_with_retry(
  sequence_number: Int,
  code: Option(Int),
  message: Option(String),
  retry_after: Int,
) -> SummaryNack {
  SummaryNack(
    summary_sequence_number: sequence_number,
    code: code,
    message: message,
    retry_after: option.Some(retry_after),
  )
}

/// Create a SummaryContext for document open response
pub fn create_summary_context(handle: String, sequence_number: Int) -> SummaryContext {
  SummaryContext(handle: handle, sequence_number: sequence_number)
}
