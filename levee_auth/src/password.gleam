//// Password hashing and verification using Argon2id.
////
//// Uses the argus library which wraps the Argon2 reference C implementation.

import argus
import gleam/result

/// Errors that can occur during password operations.
pub type PasswordError {
  HashingFailed
  VerificationFailed
}

/// Configuration for password hashing.
/// Uses OWASP recommended defaults for Argon2id.
pub type HashConfig {
  HashConfig(
    /// Number of iterations (time cost). Higher = more secure but slower.
    time_cost: Int,
    /// Memory usage in kibibytes. Higher = more memory-hard.
    memory_cost: Int,
    /// Degree of parallelism.
    parallelism: Int,
    /// Length of the hash output in bytes.
    hash_length: Int,
  )
}

/// Default configuration following OWASP recommendations.
/// - time_cost: 3 iterations
/// - memory_cost: 12288 KiB (12 MiB)
/// - parallelism: 1
/// - hash_length: 32 bytes
pub fn default_config() -> HashConfig {
  HashConfig(time_cost: 3, memory_cost: 12_288, parallelism: 1, hash_length: 32)
}

/// Hash a password using Argon2id with the provided configuration.
/// Returns an encoded hash string that includes the algorithm parameters and salt.
pub fn hash_with_config(
  password: String,
  config: HashConfig,
) -> Result(String, PasswordError) {
  let salt = argus.gen_salt()

  argus.hasher()
  |> argus.algorithm(argus.Argon2id)
  |> argus.time_cost(config.time_cost)
  |> argus.memory_cost(config.memory_cost)
  |> argus.parallelism(config.parallelism)
  |> argus.hash_length(config.hash_length)
  |> argus.hash(password, salt)
  |> result.map(fn(hashes) { hashes.encoded_hash })
  |> result.replace_error(HashingFailed)
}

/// Hash a password using Argon2id with default configuration.
/// This is the recommended function for most use cases.
pub fn hash(password: String) -> Result(String, PasswordError) {
  hash_with_config(password, default_config())
}

/// Verify a password against an encoded Argon2 hash.
/// Returns Ok(True) if the password matches, Ok(False) if it doesn't,
/// or Error if verification fails.
pub fn verify(
  password: String,
  encoded_hash: String,
) -> Result(Bool, PasswordError) {
  argus.verify(encoded_hash, password)
  |> result.replace_error(VerificationFailed)
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
