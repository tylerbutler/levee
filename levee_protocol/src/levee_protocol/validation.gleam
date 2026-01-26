/// Message validation for Fluid Framework protocol
///
/// Validates incoming messages against protocol requirements

import gleam/int
import gleam/list
import gleam/result

import levee_protocol/types.{
  type ConnectionMode, type DocumentMessage, type TokenClaims, ReadMode,
  WriteMode,
}

/// Validation error
pub type ValidationError {
  /// Message is too large
  MessageTooLarge(max: Int, actual: Int)
  /// Required field is missing
  MissingField(name: String)
  /// Field has invalid value
  InvalidField(name: String, reason: String)
  /// Client sequence number is invalid
  InvalidClientSequenceNumber(expected_gt: Int, received: Int)
  /// Reference sequence number is invalid
  InvalidReferenceSequenceNumber(current_sn: Int, received: Int)
  /// Token is expired
  TokenExpired(expired_at: Int, current_time: Int)
  /// Token missing required scope
  MissingScope(required: String, available: List(String))
  /// Client mode doesn't allow operation
  OperationNotAllowed(mode: ConnectionMode, operation: String)
}

/// Validation result
pub type ValidationResult(a) =
  Result(a, ValidationError)

/// Validate message size
pub fn validate_message_size(
  message_bytes: Int,
  max_size: Int,
) -> ValidationResult(Nil) {
  case message_bytes <= max_size {
    True -> Ok(Nil)
    False -> Error(MessageTooLarge(max: max_size, actual: message_bytes))
  }
}

/// Validate that client has write mode
pub fn validate_write_mode(mode: ConnectionMode) -> ValidationResult(Nil) {
  case mode {
    WriteMode -> Ok(Nil)
    ReadMode -> Error(OperationNotAllowed(mode: ReadMode, operation: "submitOp"))
  }
}

/// Validate that token has required scope
pub fn validate_scope(
  claims: TokenClaims,
  required_scope: String,
) -> ValidationResult(Nil) {
  case list.contains(claims.scopes, required_scope) {
    True -> Ok(Nil)
    False ->
      Error(MissingScope(required: required_scope, available: claims.scopes))
  }
}

/// Validate token is not expired
pub fn validate_token_expiration(
  claims: TokenClaims,
  current_time_seconds: Int,
) -> ValidationResult(Nil) {
  case claims.expiration > current_time_seconds {
    True -> Ok(Nil)
    False ->
      Error(TokenExpired(
        expired_at: claims.expiration,
        current_time: current_time_seconds,
      ))
  }
}

/// Validate token claims match request
pub fn validate_token_claims(
  claims: TokenClaims,
  tenant_id: String,
  document_id: String,
) -> ValidationResult(Nil) {
  case claims.tenant_id == tenant_id {
    False ->
      Error(InvalidField(
        name: "tenantId",
        reason: "Token tenant does not match request",
      ))
    True ->
      case claims.document_id == document_id {
        False ->
          Error(InvalidField(
            name: "documentId",
            reason: "Token document does not match request",
          ))
        True -> Ok(Nil)
      }
  }
}

/// Validate client sequence number
pub fn validate_csn(
  received_csn: Int,
  last_csn: Int,
) -> ValidationResult(Nil) {
  case received_csn > last_csn {
    True -> Ok(Nil)
    False ->
      Error(InvalidClientSequenceNumber(
        expected_gt: last_csn,
        received: received_csn,
      ))
  }
}

/// Validate reference sequence number
pub fn validate_rsn(
  received_rsn: Int,
  current_sn: Int,
) -> ValidationResult(Nil) {
  case received_rsn <= current_sn {
    True -> Ok(Nil)
    False ->
      Error(InvalidReferenceSequenceNumber(
        current_sn: current_sn,
        received: received_rsn,
      ))
  }
}

/// Validate a complete document message for submission
pub fn validate_document_message(
  msg: DocumentMessage,
  client_mode: ConnectionMode,
  last_csn: Int,
  current_sn: Int,
  max_message_size: Int,
  message_bytes: Int,
) -> ValidationResult(Nil) {
  // Chain validations
  use _ <- result.try(validate_write_mode(client_mode))
  use _ <- result.try(validate_message_size(message_bytes, max_message_size))
  use _ <- result.try(validate_csn(msg.client_sequence_number, last_csn))
  use _ <- result.try(validate_rsn(msg.reference_sequence_number, current_sn))
  Ok(Nil)
}

/// Format validation error as human-readable message
pub fn format_error(error: ValidationError) -> String {
  case error {
    MessageTooLarge(max, actual) ->
      "Message size "
      <> int.to_string(actual)
      <> " exceeds limit "
      <> int.to_string(max)

    MissingField(name) -> "Missing required field: " <> name

    InvalidField(name, reason) -> "Invalid field '" <> name <> "': " <> reason

    InvalidClientSequenceNumber(expected_gt, received) ->
      "Invalid client sequence number: expected > "
      <> int.to_string(expected_gt)
      <> ", received "
      <> int.to_string(received)

    InvalidReferenceSequenceNumber(current_sn, received) ->
      "Invalid reference sequence number: current SN is "
      <> int.to_string(current_sn)
      <> ", received RSN "
      <> int.to_string(received)

    TokenExpired(expired_at, _current_time) ->
      "Token expired at " <> int.to_string(expired_at)

    MissingScope(required, _available) -> "Missing required scope: " <> required

    OperationNotAllowed(_mode, operation) ->
      "Operation '" <> operation <> "' not allowed in read-only mode"
  }
}
