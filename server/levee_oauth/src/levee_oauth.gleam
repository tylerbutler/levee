/// OAuth authentication for Levee using vestibule.
///
/// Provides two-phase OAuth flow:
/// 1. `begin_auth` — generates authorization URL, stores CSRF state
/// 2. `complete_auth` — validates state, exchanges code, returns Auth result
import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/result

import vestibule
import vestibule/auth.{type Auth}
import vestibule/authorization_request.{AuthorizationRequest}
import vestibule/strategy.{type Strategy}
import vestibule/strategy/github

import levee_oauth/config
import levee_oauth/error.{
  type OAuthError, StateStoreUnavailable, UnknownProvider, VestibuleError,
}
import levee_oauth/state_store

/// Default CSRF state TTL in seconds (3 minutes).
const state_ttl_seconds = 180

/// Phase 1: Begin OAuth flow. Returns the authorization URL to redirect to.
/// Stores CSRF state and PKCE code verifier in the state store with a 3-minute TTL.
pub fn begin_auth(
  provider: String,
  store: Subject(state_store.Message),
) -> Result(String, OAuthError) {
  use strategy <- require_strategy(provider)
  use oauth_config <- result.try(config.load_github_config())

  case vestibule.authorize_url(strategy, oauth_config) {
    Ok(AuthorizationRequest(url:, state:, code_verifier:)) -> {
      state_store.store(store, state, code_verifier, state_ttl_seconds)
      Ok(url)
    }
    Error(err) -> Error(VestibuleError(err))
  }
}

/// Phase 2: Complete OAuth flow. Validates CSRF state, exchanges code
/// for credentials, and returns normalized Auth result.
pub fn complete_auth(
  provider: String,
  code: String,
  state: String,
  store: Subject(state_store.Message),
) -> Result(Auth, OAuthError) {
  use strategy <- require_strategy(provider)
  use oauth_config <- result.try(config.load_github_config())

  // Validate and consume CSRF state, recovering the code verifier
  use code_verifier <- result.try(
    state_store.validate_and_consume(store, state)
    |> result.replace_error(StateStoreUnavailable),
  )

  // Build callback params dict
  let callback_params =
    dict.from_list([#("code", code), #("state", state)])

  // Call vestibule to exchange code and fetch user
  case
    vestibule.handle_callback(
      strategy,
      oauth_config,
      callback_params,
      state,
      code_verifier,
    )
  {
    Ok(auth) -> Ok(auth)
    Error(err) -> Error(VestibuleError(err))
  }
}

fn require_strategy(
  provider: String,
  next: fn(Strategy(Nil)) -> Result(a, OAuthError),
) -> Result(a, OAuthError) {
  case provider {
    "github" -> next(github.strategy())
    _ -> Error(UnknownProvider(name: provider))
  }
}
