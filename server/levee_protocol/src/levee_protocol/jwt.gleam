/// JWT validation for Fluid Framework protocol
///
/// Provides token claims validation per spec section 3:
/// - Document match
/// - Tenant match
/// - Expiration check
/// - Scope checking
import gleam/int
import gleam/list
import gleam/result

import levee_protocol/types.{type TokenClaims}

/// JWT validation error types
pub type JwtValidationError {
  /// Token has expired
  TokenExpired(expired_at: Int, current_time: Int)
  /// Token tenant doesn't match request
  TenantMismatch(token_tenant: String, request_tenant: String)
  /// Token document doesn't match request
  DocumentMismatch(token_document: String, request_document: String)
  /// Token missing required scope
  MissingScope(required: String, available: List(String))
  /// Token is missing a required claim
  MissingClaim(claim_name: String)
  /// Token claim has invalid value
  InvalidClaim(claim_name: String, reason: String)
}

/// Validation result type
pub type JwtValidationResult(a) =
  Result(a, JwtValidationError)

/// Standard permission scopes
pub const scope_doc_read = "doc:read"

pub const scope_doc_write = "doc:write"

pub const scope_summary_write = "summary:write"

/// Validate that the token has not expired
pub fn validate_expiration(
  claims: TokenClaims,
  current_time_seconds: Int,
) -> JwtValidationResult(Nil) {
  case claims.expiration > current_time_seconds {
    True -> Ok(Nil)
    False ->
      Error(TokenExpired(
        expired_at: claims.expiration,
        current_time: current_time_seconds,
      ))
  }
}

/// Validate that the token tenant matches the request tenant
pub fn validate_tenant(
  claims: TokenClaims,
  request_tenant_id: String,
) -> JwtValidationResult(Nil) {
  case claims.tenant_id == request_tenant_id {
    True -> Ok(Nil)
    False ->
      Error(TenantMismatch(
        token_tenant: claims.tenant_id,
        request_tenant: request_tenant_id,
      ))
  }
}

/// Validate that the token document matches the request document
pub fn validate_document(
  claims: TokenClaims,
  request_document_id: String,
) -> JwtValidationResult(Nil) {
  case claims.document_id == request_document_id {
    True -> Ok(Nil)
    False ->
      Error(DocumentMismatch(
        token_document: claims.document_id,
        request_document: request_document_id,
      ))
  }
}

/// Validate that the token has the required scope
pub fn validate_scope(
  claims: TokenClaims,
  required_scope: String,
) -> JwtValidationResult(Nil) {
  case list.contains(claims.scopes, required_scope) {
    True -> Ok(Nil)
    False ->
      Error(MissingScope(required: required_scope, available: claims.scopes))
  }
}

/// Check if token has a specific scope (returns Bool, doesn't error)
pub fn has_scope(claims: TokenClaims, scope: String) -> Bool {
  list.contains(claims.scopes, scope)
}

/// Check if token has read permission
pub fn has_read_scope(claims: TokenClaims) -> Bool {
  has_scope(claims, scope_doc_read)
}

/// Check if token has write permission
pub fn has_write_scope(claims: TokenClaims) -> Bool {
  has_scope(claims, scope_doc_write)
}

/// Check if token has summary write permission
pub fn has_summary_write_scope(claims: TokenClaims) -> Bool {
  has_scope(claims, scope_summary_write)
}

/// Validate all claims for a document connection
/// Per spec section 3.3:
/// 1. Expiration check
/// 2. Tenant match
/// 3. Document match
pub fn validate_connection_claims(
  claims: TokenClaims,
  tenant_id: String,
  document_id: String,
  current_time_seconds: Int,
) -> JwtValidationResult(Nil) {
  use _ <- result.try(validate_expiration(claims, current_time_seconds))
  use _ <- result.try(validate_tenant(claims, tenant_id))
  use _ <- result.try(validate_document(claims, document_id))
  Ok(Nil)
}

/// Validate claims for read access
/// Requires doc:read scope in addition to connection validation
pub fn validate_read_access(
  claims: TokenClaims,
  tenant_id: String,
  document_id: String,
  current_time_seconds: Int,
) -> JwtValidationResult(Nil) {
  use _ <- result.try(validate_connection_claims(
    claims,
    tenant_id,
    document_id,
    current_time_seconds,
  ))
  use _ <- result.try(validate_scope(claims, scope_doc_read))
  Ok(Nil)
}

/// Validate claims for write access
/// Requires doc:write scope in addition to read access validation
pub fn validate_write_access(
  claims: TokenClaims,
  tenant_id: String,
  document_id: String,
  current_time_seconds: Int,
) -> JwtValidationResult(Nil) {
  use _ <- result.try(validate_read_access(
    claims,
    tenant_id,
    document_id,
    current_time_seconds,
  ))
  use _ <- result.try(validate_scope(claims, scope_doc_write))
  Ok(Nil)
}

/// Validate claims for summary write access
/// Requires summary:write scope in addition to read access
pub fn validate_summary_access(
  claims: TokenClaims,
  tenant_id: String,
  document_id: String,
  current_time_seconds: Int,
) -> JwtValidationResult(Nil) {
  use _ <- result.try(validate_read_access(
    claims,
    tenant_id,
    document_id,
    current_time_seconds,
  ))
  use _ <- result.try(validate_scope(claims, scope_summary_write))
  Ok(Nil)
}

/// Format JWT validation error as human-readable message
pub fn format_error(error: JwtValidationError) -> String {
  case error {
    TokenExpired(expired_at, current_time) ->
      "Token expired at "
      <> int.to_string(expired_at)
      <> " (current time: "
      <> int.to_string(current_time)
      <> ")"

    TenantMismatch(token_tenant, request_tenant) ->
      "Token tenant '"
      <> token_tenant
      <> "' does not match request tenant '"
      <> request_tenant
      <> "'"

    DocumentMismatch(token_document, request_document) ->
      "Token document '"
      <> token_document
      <> "' does not match request document '"
      <> request_document
      <> "'"

    MissingScope(required, _available) -> "Missing required scope: " <> required

    MissingClaim(claim_name) -> "Missing required claim: " <> claim_name

    InvalidClaim(claim_name, reason) ->
      "Invalid claim '" <> claim_name <> "': " <> reason
  }
}

/// Get HTTP status code for JWT validation error
pub fn error_to_http_code(error: JwtValidationError) -> Int {
  case error {
    TokenExpired(_, _) -> 401
    TenantMismatch(_, _) -> 403
    DocumentMismatch(_, _) -> 403
    MissingScope(_, _) -> 403
    MissingClaim(_) -> 401
    InvalidClaim(_, _) -> 401
  }
}
