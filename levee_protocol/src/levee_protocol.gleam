//// Fluid Protocol - Type-safe Fluid Framework protocol implementation
////
//// This module provides the main API for the Elixir interop layer.
//// All core types and functions are re-exported here.

import levee_protocol/jwt
import levee_protocol/message
import levee_protocol/nack
import levee_protocol/sequencing
import levee_protocol/summary
import levee_protocol/types
import levee_protocol/validation
import gleam/option

// Expose types module
pub type ConnectionMode =
  types.ConnectionMode

pub type User =
  types.User

pub type Client =
  types.Client

pub type TokenClaims =
  types.TokenClaims

pub type DocumentMessage =
  types.DocumentMessage

pub type SequencedDocumentMessage =
  types.SequencedDocumentMessage

pub type ServiceConfiguration =
  types.ServiceConfiguration

// Expose sequencing module
pub type SequenceState =
  sequencing.SequenceState

pub type SequenceResult =
  sequencing.SequenceResult

pub type SequenceError =
  sequencing.SequenceError

// Expose nack module
pub type Nack =
  nack.Nack

pub type NackErrorType =
  nack.NackErrorType

pub type NackContent =
  nack.NackContent

// Expose message module
pub type ConnectMessage =
  message.ConnectMessage

pub type ConnectedMessage =
  message.ConnectedMessage

pub type ConnectError =
  message.ConnectError

pub type SignalMessage =
  message.SignalMessage

pub type MessageType =
  message.MessageType

// Expose validation module
pub type ValidationError =
  validation.ValidationError

// Expose summary module
pub type SummaryTree =
  summary.SummaryTree

pub type SummaryObject =
  summary.SummaryObject

pub type SummaryType =
  summary.SummaryType

pub type SummaryOp =
  summary.SummaryOp

pub type SummaryAck =
  summary.SummaryAck

pub type SummaryNack =
  summary.SummaryNack

pub type SummaryContext =
  summary.SummaryContext

// Expose JWT module
pub type JwtValidationError =
  jwt.JwtValidationError

// ─────────────────────────────────────────────────────────────────────────────
// Sequencing API (main entry points for Elixir)
// ─────────────────────────────────────────────────────────────────────────────

/// Create a new sequence state for a document
pub fn new_sequence_state() -> SequenceState {
  sequencing.new()
}

/// Create sequence state from checkpoint
pub fn sequence_state_from_checkpoint(sn: Int, msn: Int) -> SequenceState {
  sequencing.from_checkpoint(sn, msn)
}

/// Register a client joining the session
pub fn client_join(
  state: SequenceState,
  client_id: String,
  join_rsn: Int,
) -> SequenceState {
  sequencing.client_join(state, client_id, join_rsn)
}

/// Remove a client from the session
pub fn client_leave(state: SequenceState, client_id: String) -> SequenceState {
  sequencing.client_leave(state, client_id)
}

/// Assign a sequence number to an operation
pub fn assign_sequence_number(
  state: SequenceState,
  client_id: String,
  csn: Int,
  rsn: Int,
) -> SequenceResult {
  sequencing.assign_sequence_number(state, client_id, csn, rsn)
}

/// Get current sequence number
pub fn current_sn(state: SequenceState) -> Int {
  sequencing.current_sn(state)
}

/// Get current minimum sequence number
pub fn current_msn(state: SequenceState) -> Int {
  sequencing.current_msn(state)
}

/// Get count of connected clients
pub fn client_count(state: SequenceState) -> Int {
  sequencing.client_count(state)
}

/// Check if client is connected
pub fn is_client_connected(state: SequenceState, client_id: String) -> Bool {
  sequencing.is_client_connected(state, client_id)
}

/// Get list of connected client IDs
pub fn connected_clients(state: SequenceState) -> List(String) {
  sequencing.connected_clients(state)
}

// ─────────────────────────────────────────────────────────────────────────────
// Nack API
// ─────────────────────────────────────────────────────────────────────────────

/// Create a bad request nack
pub fn nack_bad_request(
  message: String,
  op: option.Option(types.DocumentMessage),
) -> Nack {
  nack.bad_request(message, op)
}

/// Create an invalid scope nack
pub fn nack_invalid_scope(
  required_scope: String,
  op: option.Option(types.DocumentMessage),
) -> Nack {
  nack.invalid_scope(required_scope, op)
}

/// Create a throttled nack
pub fn nack_throttled(
  retry_after: Int,
  op: option.Option(types.DocumentMessage),
) -> Nack {
  nack.throttled(retry_after, op)
}

/// Create a read-only client nack
pub fn nack_read_only_client(op: option.Option(types.DocumentMessage)) -> Nack {
  nack.read_only_client(op)
}

// ─────────────────────────────────────────────────────────────────────────────
// Validation API
// ─────────────────────────────────────────────────────────────────────────────

/// Validate message size
pub fn validate_message_size(
  message_bytes: Int,
  max_size: Int,
) -> Result(Nil, ValidationError) {
  validation.validate_message_size(message_bytes, max_size)
}

/// Validate write mode
pub fn validate_write_mode(
  mode: types.ConnectionMode,
) -> Result(Nil, ValidationError) {
  validation.validate_write_mode(mode)
}

/// Validate token has required scope
pub fn validate_scope(
  claims: TokenClaims,
  required_scope: String,
) -> Result(Nil, ValidationError) {
  validation.validate_scope(claims, required_scope)
}

/// Validate token expiration
pub fn validate_token_expiration(
  claims: TokenClaims,
  current_time_seconds: Int,
) -> Result(Nil, ValidationError) {
  validation.validate_token_expiration(claims, current_time_seconds)
}

/// Format validation error as string
pub fn format_validation_error(error: ValidationError) -> String {
  validation.format_error(error)
}

// ─────────────────────────────────────────────────────────────────────────────
// Message Type API
// ─────────────────────────────────────────────────────────────────────────────

/// Convert message type to string
pub fn message_type_to_string(mt: MessageType) -> String {
  message.message_type_to_string(mt)
}

/// Parse message type from string
pub fn message_type_from_string(s: String) -> Result(MessageType, Nil) {
  message.message_type_from_string(s)
}

// ─────────────────────────────────────────────────────────────────────────────
// Type constructors (for Elixir to create Gleam types)
// ─────────────────────────────────────────────────────────────────────────────

pub fn write_mode() -> types.ConnectionMode {
  types.WriteMode
}

pub fn read_mode() -> types.ConnectionMode {
  types.ReadMode
}

pub fn nack_error_throttling() -> NackErrorType {
  nack.ThrottlingError
}

pub fn nack_error_invalid_scope() -> NackErrorType {
  nack.InvalidScopeError
}

pub fn nack_error_bad_request() -> NackErrorType {
  nack.BadRequestError
}

pub fn nack_error_limit_exceeded() -> NackErrorType {
  nack.LimitExceededError
}

// ─────────────────────────────────────────────────────────────────────────────
// JWT Validation API
// ─────────────────────────────────────────────────────────────────────────────

/// Standard permission scopes
pub const jwt_scope_doc_read = jwt.scope_doc_read

pub const jwt_scope_doc_write = jwt.scope_doc_write

pub const jwt_scope_summary_write = jwt.scope_summary_write

/// Validate that the token has not expired
pub fn jwt_validate_expiration(
  claims: TokenClaims,
  current_time_seconds: Int,
) -> Result(Nil, JwtValidationError) {
  jwt.validate_expiration(claims, current_time_seconds)
}

/// Validate that the token tenant matches the request tenant
pub fn jwt_validate_tenant(
  claims: TokenClaims,
  request_tenant_id: String,
) -> Result(Nil, JwtValidationError) {
  jwt.validate_tenant(claims, request_tenant_id)
}

/// Validate that the token document matches the request document
pub fn jwt_validate_document(
  claims: TokenClaims,
  request_document_id: String,
) -> Result(Nil, JwtValidationError) {
  jwt.validate_document(claims, request_document_id)
}

/// Validate that the token has the required scope
pub fn jwt_validate_scope(
  claims: TokenClaims,
  required_scope: String,
) -> Result(Nil, JwtValidationError) {
  jwt.validate_scope(claims, required_scope)
}

/// Check if token has a specific scope (returns Bool)
pub fn jwt_has_scope(claims: TokenClaims, scope: String) -> Bool {
  jwt.has_scope(claims, scope)
}

/// Check if token has read permission
pub fn jwt_has_read_scope(claims: TokenClaims) -> Bool {
  jwt.has_read_scope(claims)
}

/// Check if token has write permission
pub fn jwt_has_write_scope(claims: TokenClaims) -> Bool {
  jwt.has_write_scope(claims)
}

/// Check if token has summary write permission
pub fn jwt_has_summary_write_scope(claims: TokenClaims) -> Bool {
  jwt.has_summary_write_scope(claims)
}

/// Validate all claims for a document connection
pub fn jwt_validate_connection_claims(
  claims: TokenClaims,
  tenant_id: String,
  document_id: String,
  current_time_seconds: Int,
) -> Result(Nil, JwtValidationError) {
  jwt.validate_connection_claims(claims, tenant_id, document_id, current_time_seconds)
}

/// Validate claims for read access
pub fn jwt_validate_read_access(
  claims: TokenClaims,
  tenant_id: String,
  document_id: String,
  current_time_seconds: Int,
) -> Result(Nil, JwtValidationError) {
  jwt.validate_read_access(claims, tenant_id, document_id, current_time_seconds)
}

/// Validate claims for write access
pub fn jwt_validate_write_access(
  claims: TokenClaims,
  tenant_id: String,
  document_id: String,
  current_time_seconds: Int,
) -> Result(Nil, JwtValidationError) {
  jwt.validate_write_access(claims, tenant_id, document_id, current_time_seconds)
}

/// Validate claims for summary write access
pub fn jwt_validate_summary_access(
  claims: TokenClaims,
  tenant_id: String,
  document_id: String,
  current_time_seconds: Int,
) -> Result(Nil, JwtValidationError) {
  jwt.validate_summary_access(claims, tenant_id, document_id, current_time_seconds)
}

/// Format JWT validation error as human-readable message
pub fn jwt_format_error(error: JwtValidationError) -> String {
  jwt.format_error(error)
}

/// Get HTTP status code for JWT validation error
pub fn jwt_error_to_http_code(error: JwtValidationError) -> Int {
  jwt.error_to_http_code(error)
}

// ─────────────────────────────────────────────────────────────────────────────
// Summary API
// ─────────────────────────────────────────────────────────────────────────────

/// Create an empty summary tree
pub fn empty_summary_tree() -> SummaryTree {
  summary.empty_summary_tree()
}

/// Create a summary tree with entries
pub fn new_summary_tree(entries: List(#(String, summary.SummaryObject))) -> SummaryTree {
  summary.new_summary_tree(entries)
}

/// Add an entry to a summary tree
pub fn add_to_summary_tree(
  tree: SummaryTree,
  path: String,
  object: summary.SummaryObject,
) -> SummaryTree {
  summary.add_to_summary_tree(tree, path, object)
}

/// Get an entry from a summary tree
pub fn get_from_summary_tree(
  tree: SummaryTree,
  path: String,
) -> Result(summary.SummaryObject, Nil) {
  summary.get_from_summary_tree(tree, path)
}

/// Create a SummaryAck
pub fn create_summary_ack(handle: String, sequence_number: Int) -> SummaryAck {
  summary.create_summary_ack(handle, sequence_number)
}

/// Create a SummaryNack with error message
pub fn create_summary_nack(
  sequence_number: Int,
  code: option.Option(Int),
  message: option.Option(String),
) -> SummaryNack {
  summary.create_summary_nack(sequence_number, code, message)
}

/// Create a SummaryContext for document open response
pub fn create_summary_context(handle: String, sequence_number: Int) -> SummaryContext {
  summary.create_summary_context(handle, sequence_number)
}

/// Convert SummaryType to string
pub fn summary_type_to_string(st: SummaryType) -> String {
  summary.summary_type_to_string(st)
}

/// Parse SummaryType from string
pub fn summary_type_from_string(s: String) -> Result(SummaryType, Nil) {
  summary.summary_type_from_string(s)
}

/// Convert SummaryType to numeric code
pub fn summary_type_to_code(st: SummaryType) -> Int {
  summary.summary_type_to_code(st)
}

/// Parse SummaryType from numeric code
pub fn summary_type_from_code(code: Int) -> Result(SummaryType, Nil) {
  summary.summary_type_from_code(code)
}

/// Summary type constructors
pub fn summary_type_tree() -> SummaryType {
  summary.Tree
}

pub fn summary_type_blob() -> SummaryType {
  summary.Blob
}

pub fn summary_type_attachment() -> SummaryType {
  summary.Attachment
}

/// Summary object constructors
pub fn summary_blob(content: String) -> summary.SummaryObject {
  summary.SummaryBlob(content)
}

pub fn summary_handle(handle: String, handle_type: SummaryType) -> summary.SummaryObject {
  summary.SummaryHandle(handle, handle_type)
}

pub fn summary_attachment(id: String) -> summary.SummaryObject {
  summary.SummaryAttachment(id)
}
