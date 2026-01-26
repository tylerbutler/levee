//// Fluid Protocol - Type-safe Fluid Framework protocol implementation
////
//// This module provides the main API for the Elixir interop layer.
//// All core types and functions are re-exported here.

import fluid_protocol/message
import fluid_protocol/nack
import fluid_protocol/sequencing
import fluid_protocol/types
import fluid_protocol/validation
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
