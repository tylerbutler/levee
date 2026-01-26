/// Nack (Negative Acknowledgment) types for Fluid Framework protocol
///
/// Nacks are sent when operations or signals are rejected by the server

import gleam/int
import gleam/option.{type Option}

import fluid_protocol/types.{type DocumentMessage}

/// Error type classification
pub type NackErrorType {
  /// Rate limit exceeded; retry after retryAfter seconds (429)
  ThrottlingError
  /// Token lacks required scope; obtain new token (403)
  InvalidScopeError
  /// Malformed request; fix and retry immediately (400)
  BadRequestError
  /// Server limit exceeded; do not retry (429)
  LimitExceededError
}

/// Convert nack error type to wire format string
pub fn nack_error_type_to_string(t: NackErrorType) -> String {
  case t {
    ThrottlingError -> "ThrottlingError"
    InvalidScopeError -> "InvalidScopeError"
    BadRequestError -> "BadRequestError"
    LimitExceededError -> "LimitExceededError"
  }
}

/// Parse nack error type from wire format string
pub fn nack_error_type_from_string(s: String) -> Result(NackErrorType, Nil) {
  case s {
    "ThrottlingError" -> Ok(ThrottlingError)
    "InvalidScopeError" -> Ok(InvalidScopeError)
    "BadRequestError" -> Ok(BadRequestError)
    "LimitExceededError" -> Ok(LimitExceededError)
    _ -> Error(Nil)
  }
}

/// Nack content (error details)
pub type NackContent {
  NackContent(
    /// HTTP-style error code
    code: Int,
    /// Error type classification
    error_type: NackErrorType,
    /// Human-readable error message
    message: String,
    /// Seconds to wait before retry (throttling only)
    retry_after: Option(Int),
  )
}

/// Nack message sent to client
pub type Nack {
  Nack(
    /// The rejected operation (may be None)
    operation: Option(DocumentMessage),
    /// Sequence number to catch up to (-1 for non-op nacks)
    sequence_number: Int,
    /// Error details
    content: NackContent,
  )
}

/// Create a nack for an invalid message format
pub fn bad_request(message: String, op: Option(DocumentMessage)) -> Nack {
  Nack(
    operation: op,
    sequence_number: -1,
    content: NackContent(
      code: 400,
      error_type: BadRequestError,
      message: message,
      retry_after: option.None,
    ),
  )
}

/// Create a nack for missing required scope
pub fn invalid_scope(required_scope: String, op: Option(DocumentMessage)) -> Nack {
  Nack(
    operation: op,
    sequence_number: -1,
    content: NackContent(
      code: 403,
      error_type: InvalidScopeError,
      message: "Missing required scope: " <> required_scope,
      retry_after: option.None,
    ),
  )
}

/// Create a nack for rate limiting
pub fn throttled(retry_after_seconds: Int, op: Option(DocumentMessage)) -> Nack {
  Nack(
    operation: op,
    sequence_number: -1,
    content: NackContent(
      code: 429,
      error_type: ThrottlingError,
      message: "Rate limit exceeded",
      retry_after: option.Some(retry_after_seconds),
    ),
  )
}

/// Create a nack for server limit exceeded
pub fn limit_exceeded(message: String, op: Option(DocumentMessage)) -> Nack {
  Nack(
    operation: op,
    sequence_number: -1,
    content: NackContent(
      code: 429,
      error_type: LimitExceededError,
      message: message,
      retry_after: option.None,
    ),
  )
}

/// Create a nack for read-only client trying to write
pub fn read_only_client(op: Option(DocumentMessage)) -> Nack {
  Nack(
    operation: op,
    sequence_number: -1,
    content: NackContent(
      code: 400,
      error_type: BadRequestError,
      message: "Client is in read-only mode",
      retry_after: option.None,
    ),
  )
}

/// Create a nack for invalid CSN
pub fn invalid_csn(
  expected: Int,
  received: Int,
  op: Option(DocumentMessage),
) -> Nack {
  Nack(
    operation: op,
    sequence_number: -1,
    content: NackContent(
      code: 400,
      error_type: BadRequestError,
      message: "Invalid client sequence number: expected > "
        <> int.to_string(expected)
        <> ", received "
        <> int.to_string(received),
      retry_after: option.None,
    ),
  )
}

/// Create a nack for message too large
pub fn message_too_large(
  max_size: Int,
  actual_size: Int,
  op: Option(DocumentMessage),
) -> Nack {
  Nack(
    operation: op,
    sequence_number: -1,
    content: NackContent(
      code: 413,
      error_type: BadRequestError,
      message: "Message size "
        <> int.to_string(actual_size)
        <> " exceeds limit "
        <> int.to_string(max_size),
      retry_after: option.None,
    ),
  )
}
