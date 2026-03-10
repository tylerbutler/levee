import envoy
import gleam/result
import gleam/string

import vestibule/config as vestibule_config

import levee_oauth/error.{type OAuthError, ConfigMissing}

/// Load GitHub OAuth config from environment variables.
/// Reads GITHUB_CLIENT_ID, GITHUB_CLIENT_SECRET, GITHUB_REDIRECT_URI.
/// Requests read:org scope to support team membership checks.
pub fn load_github_config() -> Result(vestibule_config.Config, OAuthError) {
  use client_id <- result.try(require_env("GITHUB_CLIENT_ID"))
  use client_secret <- result.try(require_env("GITHUB_CLIENT_SECRET"))
  use redirect_uri <- result.try(require_env("GITHUB_REDIRECT_URI"))
  build_github_config(client_id, client_secret, redirect_uri)
}

/// Build a GitHub OAuth config from explicit values.
/// Validates that no values are empty strings.
pub fn build_github_config(
  client_id: String,
  client_secret: String,
  redirect_uri: String,
) -> Result(vestibule_config.Config, OAuthError) {
  use <- guard_not_empty(client_id, "GITHUB_CLIENT_ID")
  use <- guard_not_empty(client_secret, "GITHUB_CLIENT_SECRET")
  use <- guard_not_empty(redirect_uri, "GITHUB_REDIRECT_URI")
  let config =
    vestibule_config.new(client_id, client_secret, redirect_uri)
    |> vestibule_config.with_scopes(["user:email", "read:org"])
  Ok(config)
}

fn require_env(name: String) -> Result(String, OAuthError) {
  case envoy.get(name) {
    Ok(value) ->
      case string.is_empty(value) {
        True -> Error(ConfigMissing(variable: name))
        False -> Ok(value)
      }
    Error(Nil) -> Error(ConfigMissing(variable: name))
  }
}

fn guard_not_empty(
  value: String,
  name: String,
  next: fn() -> Result(vestibule_config.Config, OAuthError),
) -> Result(vestibule_config.Config, OAuthError) {
  case string.is_empty(value) {
    True -> Error(ConfigMissing(variable: name))
    False -> next()
  }
}
