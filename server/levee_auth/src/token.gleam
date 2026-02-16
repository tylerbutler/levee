//// JWT token creation and verification for Levee authentication.
////
//// Uses the gwt library for HS256 signed JWTs.

import gleam/dynamic/decode
import gleam/float
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/timestamp
import gwt
import scopes.{type Scope}

/// Claims contained in a Levee JWT token.
pub type TokenClaims {
  TokenClaims(
    /// Unique user identifier
    user_id: String,
    /// Tenant this token is scoped to
    tenant_id: String,
    /// Document this token grants access to
    document_id: String,
    /// Authorization scopes
    scopes: List(Scope),
    /// Unix timestamp when token was issued
    iat: Int,
    /// Unix timestamp when token expires
    exp: Int,
    /// Optional unique token identifier for revocation
    token_id: Option(String),
  )
}

/// Configuration for token creation.
pub type TokenConfig {
  TokenConfig(
    /// Secret key for signing tokens
    secret: String,
    /// Token lifetime in seconds
    expires_in_seconds: Int,
  )
}

/// Errors that can occur during token operations.
pub type TokenError {
  /// Token signature is invalid
  InvalidSignature
  /// Token has expired
  TokenExpired
  /// Token is malformed or missing required claims
  MalformedToken
  /// Token is missing required claims
  MissingClaims
  /// Token was issued in the future
  TokenNotYetValid
}

/// Default token configuration with 2-hour expiration.
pub fn default_config(secret: String) -> TokenConfig {
  TokenConfig(secret: secret, expires_in_seconds: 7200)
}

/// Short-lived token configuration (15 minutes) for document access.
pub fn short_lived_config(secret: String) -> TokenConfig {
  TokenConfig(secret: secret, expires_in_seconds: 900)
}

/// Create a JWT token from claims.
pub fn create(claims: TokenClaims, config: TokenConfig) -> String {
  let scopes_str =
    claims.scopes
    |> list.map(scopes.to_string)
    |> string.join(",")

  let builder =
    gwt.new()
    |> gwt.set_subject(claims.user_id)
    |> gwt.set_issuer("levee")
    |> gwt.set_issued_at(claims.iat)
    |> gwt.set_expiration(claims.exp)
    |> gwt.set_payload_claim("tenant_id", json.string(claims.tenant_id))
    |> gwt.set_payload_claim("document_id", json.string(claims.document_id))
    |> gwt.set_payload_claim("scopes", json.string(scopes_str))

  let builder = case claims.token_id {
    Some(id) -> gwt.set_jwt_id(builder, id)
    None -> builder
  }

  gwt.to_signed_string(builder, gwt.HS256, config.secret)
}

/// Verify a JWT token and extract claims.
pub fn verify(token: String, secret: String) -> Result(TokenClaims, TokenError) {
  use jwt <- result.try(
    gwt.from_signed_string(token, secret)
    |> result.map_error(fn(e) {
      case e {
        gwt.InvalidSignature -> InvalidSignature
        gwt.TokenExpired -> TokenExpired
        gwt.TokenNotValidYet -> TokenNotYetValid
        _ -> MalformedToken
      }
    }),
  )

  // Extract standard claims
  use user_id <- result.try(
    gwt.get_subject(jwt) |> result.replace_error(MissingClaims),
  )

  use iat <- result.try(
    gwt.get_issued_at(jwt) |> result.replace_error(MissingClaims),
  )

  use exp <- result.try(
    gwt.get_expiration(jwt) |> result.replace_error(MissingClaims),
  )

  // Extract custom claims
  use tenant_id <- result.try(
    gwt.get_payload_claim(jwt, "tenant_id", decode.string)
    |> result.replace_error(MissingClaims),
  )

  use document_id <- result.try(
    gwt.get_payload_claim(jwt, "document_id", decode.string)
    |> result.replace_error(MissingClaims),
  )

  use scopes_str <- result.try(
    gwt.get_payload_claim(jwt, "scopes", decode.string)
    |> result.replace_error(MissingClaims),
  )

  let parsed_scopes =
    scopes_str
    |> string.split(",")
    |> list.filter(fn(s) { s != "" })
    |> scopes.list_from_strings()

  let token_id = case gwt.get_jwt_id(jwt) {
    Ok(id) -> Some(id)
    Error(_) -> None
  }

  Ok(TokenClaims(
    user_id: user_id,
    tenant_id: tenant_id,
    document_id: document_id,
    scopes: parsed_scopes,
    iat: iat,
    exp: exp,
    token_id: token_id,
  ))
}

/// Create claims for read-only document access.
pub fn read_only_claims(
  user_id: String,
  tenant_id: String,
  document_id: String,
  config: TokenConfig,
) -> TokenClaims {
  let now = now_unix()
  TokenClaims(
    user_id: user_id,
    tenant_id: tenant_id,
    document_id: document_id,
    scopes: scopes.read_only(),
    iat: now,
    exp: now + config.expires_in_seconds,
    token_id: None,
  )
}

/// Create claims for read-write document access.
pub fn read_write_claims(
  user_id: String,
  tenant_id: String,
  document_id: String,
  config: TokenConfig,
) -> TokenClaims {
  let now = now_unix()
  TokenClaims(
    user_id: user_id,
    tenant_id: tenant_id,
    document_id: document_id,
    scopes: scopes.read_write(),
    iat: now,
    exp: now + config.expires_in_seconds,
    token_id: None,
  )
}

/// Create claims for full document access (including summary operations).
pub fn full_access_claims(
  user_id: String,
  tenant_id: String,
  document_id: String,
  config: TokenConfig,
) -> TokenClaims {
  let now = now_unix()
  TokenClaims(
    user_id: user_id,
    tenant_id: tenant_id,
    document_id: document_id,
    scopes: scopes.full_access(),
    iat: now,
    exp: now + config.expires_in_seconds,
    token_id: None,
  )
}

/// Create a document access token with specified scopes.
pub fn create_document_token(
  user_id: String,
  tenant_id: String,
  document_id: String,
  requested_scopes: List(Scope),
  config: TokenConfig,
) -> String {
  let now = now_unix()
  let claims =
    TokenClaims(
      user_id: user_id,
      tenant_id: tenant_id,
      document_id: document_id,
      scopes: requested_scopes,
      iat: now,
      exp: now + config.expires_in_seconds,
      token_id: None,
    )
  create(claims, config)
}

/// Check if token claims grant a specific scope.
pub fn has_scope(claims: TokenClaims, scope: Scope) -> Bool {
  scopes.has_scope(claims.scopes, scope)
}

/// Check if token is expired.
pub fn is_expired(claims: TokenClaims) -> Bool {
  let now = now_unix()
  claims.exp < now
}

// Internal helpers

fn now_unix() -> Int {
  timestamp.system_time()
  |> timestamp.to_unix_seconds
  |> float.round
}
