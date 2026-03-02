//// Environment configuration for the Levee web server.

import envoy
import gleam/int
import gleam/result

/// Get the HTTP port (default: 4000).
pub fn get_port() -> Int {
  envoy.get("PORT")
  |> result.try(int.parse)
  |> result.unwrap(4000)
}

/// Get the secret key base for cookie signing.
pub fn get_secret_key_base() -> String {
  envoy.get("SECRET_KEY_BASE")
  |> result.unwrap(
    "dev-secret-key-base-that-is-at-least-64-bytes-long-for-security-purposes-only",
  )
}

/// Get the path to static files (priv/static).
pub fn get_static_path() -> String {
  envoy.get("LEVEE_STATIC_PATH")
  |> result.unwrap("../priv/static")
}
