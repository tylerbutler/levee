//// Levee Authentication Library
////
//// Provides password hashing, JWT token management, and authorization scopes
//// for the Levee collaborative document service.
////
//// ## Modules
////
//// - `levee_auth/password` - Argon2id password hashing and verification
//// - `levee_auth/token` - JWT creation and verification
//// - `levee_auth/scopes` - Authorization scope definitions
////
//// ## Example Usage
////
//// ```gleam
//// import levee_auth
//// import levee_auth/password
//// import levee_auth/token
//// import levee_auth/scopes
////
//// // Hash a password
//// let assert Ok(hash) = password.hash("user_password")
////
//// // Verify password
//// let is_valid = password.matches("user_password", hash)
////
//// // Create a document access token
//// let config = token.default_config("my-secret-key")
//// let jwt = levee_auth.create_document_token(
////   "user-123",
////   "tenant-456",
////   "doc-789",
////   scopes.read_write(),
////   config,
//// )
////
//// // Verify and extract claims
//// let assert Ok(claims) = token.verify(jwt, "my-secret-key")
//// ```

import password
import scopes.{type Scope}
import token.{type TokenClaims, type TokenConfig, type TokenError}

// Re-export main password functions

/// Hash a password using Argon2id with default settings.
pub fn hash_password(pwd: String) -> Result(String, password.PasswordError) {
  password.hash(pwd)
}

/// Verify a password against a hash. Returns True if they match.
pub fn verify_password(pwd: String, hash: String) -> Bool {
  password.matches(pwd, hash)
}

// Re-export main token functions

/// Create a document access token with the specified scopes.
pub fn create_document_token(
  user_id: String,
  tenant_id: String,
  document_id: String,
  requested_scopes: List(Scope),
  config: TokenConfig,
) -> String {
  token.create_document_token(
    user_id,
    tenant_id,
    document_id,
    requested_scopes,
    config,
  )
}

/// Verify a JWT token and extract its claims.
pub fn verify_token(
  jwt: String,
  secret: String,
) -> Result(TokenClaims, TokenError) {
  token.verify(jwt, secret)
}

/// Create default token configuration with 2-hour expiration.
pub fn default_token_config(secret: String) -> TokenConfig {
  token.default_config(secret)
}

/// Create short-lived token configuration (15 minutes).
pub fn short_lived_token_config(secret: String) -> TokenConfig {
  token.short_lived_config(secret)
}
