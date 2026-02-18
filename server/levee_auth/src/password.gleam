//// Password hashing and verification using PBKDF2-SHA256.
////
//// Uses Erlang's crypto module for PBKDF2 key derivation - no NIFs required.
//// Format: $pbkdf2-sha256$iterations$base64_salt$base64_hash

import gleam/bit_array
import gleam/crypto
import gleam/int
import gleam/string

/// Errors that can occur during password operations.
pub type PasswordError {
  HashingFailed
  InvalidHashFormat
}

/// Configuration for password hashing.
pub type HashConfig {
  HashConfig(
    /// Number of iterations. Higher = more secure but slower.
    /// OWASP recommends 600,000 for PBKDF2-SHA256.
    iterations: Int,
    /// Length of the hash output in bytes.
    hash_length: Int,
    /// Length of the salt in bytes.
    salt_length: Int,
  )
}

/// Default configuration following OWASP recommendations for PBKDF2-SHA256.
/// - iterations: 600,000 (OWASP 2023 recommendation)
/// - hash_length: 32 bytes (256 bits)
/// - salt_length: 16 bytes (128 bits)
pub fn default_config() -> HashConfig {
  HashConfig(iterations: 600_000, hash_length: 32, salt_length: 16)
}

/// Hash a password using PBKDF2-SHA256 with the provided configuration.
/// Returns an encoded hash string in the format:
/// $pbkdf2-sha256$iterations$base64_salt$base64_hash
pub fn hash_with_config(
  password: String,
  config: HashConfig,
) -> Result(String, PasswordError) {
  let salt = crypto.strong_random_bytes(config.salt_length)
  let password_bytes = bit_array.from_string(password)

  case
    pbkdf2_hmac_sha256(
      password_bytes,
      salt,
      config.iterations,
      config.hash_length,
    )
  {
    Ok(hash) -> {
      let encoded_salt = base64_encode(salt)
      let encoded_hash = base64_encode(hash)
      let iterations_str = int.to_string(config.iterations)
      Ok(
        "$pbkdf2-sha256$"
        <> iterations_str
        <> "$"
        <> encoded_salt
        <> "$"
        <> encoded_hash,
      )
    }
    Error(_) -> Error(HashingFailed)
  }
}

/// Hash a password using PBKDF2-SHA256 with default configuration.
/// This is the recommended function for most use cases.
pub fn hash(password: String) -> Result(String, PasswordError) {
  hash_with_config(password, default_config())
}

/// Verify a password against an encoded PBKDF2 hash.
/// Returns Ok(True) if the password matches, Ok(False) if it doesn't,
/// or Error if the hash format is invalid.
pub fn verify(
  password: String,
  encoded_hash: String,
) -> Result(Bool, PasswordError) {
  case parse_hash(encoded_hash) {
    Ok(#(iterations, salt, expected_hash)) -> {
      let password_bytes = bit_array.from_string(password)
      let hash_length = bit_array.byte_size(expected_hash)

      case pbkdf2_hmac_sha256(password_bytes, salt, iterations, hash_length) {
        Ok(computed_hash) -> {
          Ok(crypto.secure_compare(computed_hash, expected_hash))
        }
        Error(_) -> Error(HashingFailed)
      }
    }
    Error(_) -> Error(InvalidHashFormat)
  }
}

/// Check if a password matches a hash. Returns False on any error.
/// Convenience function that doesn't distinguish between wrong password
/// and verification failure.
pub fn matches(password: String, encoded_hash: String) -> Bool {
  case verify(password, encoded_hash) {
    Ok(True) -> True
    Ok(False) -> False
    Error(_) -> False
  }
}

/// Parse an encoded hash string into its components.
fn parse_hash(
  encoded: String,
) -> Result(#(Int, BitArray, BitArray), PasswordError) {
  case string.split(encoded, "$") {
    // Format: ["", "pbkdf2-sha256", iterations, salt, hash]
    ["", "pbkdf2-sha256", iterations_str, salt_b64, hash_b64] -> {
      case int.parse(iterations_str) {
        Ok(iterations) -> {
          case base64_decode(salt_b64), base64_decode(hash_b64) {
            Ok(salt), Ok(hash) -> Ok(#(iterations, salt, hash))
            _, _ -> Error(InvalidHashFormat)
          }
        }
        Error(_) -> Error(InvalidHashFormat)
      }
    }
    _ -> Error(InvalidHashFormat)
  }
}

// Erlang crypto:pbkdf2_hmac/5 binding
// We use a helper module to call crypto:pbkdf2_hmac(sha256, ...)
fn pbkdf2_hmac_sha256(
  password: BitArray,
  salt: BitArray,
  iterations: Int,
  key_length: Int,
) -> Result(BitArray, Nil) {
  Ok(do_pbkdf2_sha256(password, salt, iterations, key_length))
}

@external(erlang, "password_ffi", "pbkdf2_sha256")
fn do_pbkdf2_sha256(
  password: BitArray,
  salt: BitArray,
  iterations: Int,
  key_length: Int,
) -> BitArray

// Base64 encoding/decoding using Erlang's base64 module
@external(erlang, "base64", "encode")
fn erlang_base64_encode(data: BitArray) -> String

fn base64_encode(data: BitArray) -> String {
  erlang_base64_encode(data)
}

fn base64_decode(data: String) -> Result(BitArray, Nil) {
  safe_base64_decode(data)
}

@external(erlang, "password_ffi", "safe_base64_decode")
fn safe_base64_decode(data: String) -> Result(BitArray, Nil)
