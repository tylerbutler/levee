# Vestibule Integration Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the Elixir Ueberauth OAuth dependency with vestibule (Gleam-native) via a new `levee_oauth` Gleam package.

**Architecture:** New `server/levee_oauth/` Gleam package owns OAuth flow orchestration (vestibule calls, CSRF state storage). A thin Phoenix controller handles HTTP transport and delegates to `levee_oauth`. User find-or-create and session management stay in the Elixir layer using existing `GleamBridge` and `SessionStore`.

**Tech Stack:** Gleam (vestibule, gleam_otp Actor), Elixir (Phoenix controller), existing levee_auth primitives.

**Design doc:** `docs/plans/2026-02-25-vestibule-integration-design.md`

---

### Task 1: Create levee_oauth Gleam Package Skeleton

**Files:**
- Create: `server/levee_oauth/gleam.toml`
- Create: `server/levee_oauth/src/levee_oauth.gleam` (placeholder)
- Create: `server/levee_oauth/test/levee_oauth_test.gleam` (placeholder)

**Step 1: Create gleam.toml**

```toml
name = "levee_oauth"
version = "0.1.0"
target = "erlang"
description = "OAuth authentication for Levee using vestibule"

[dependencies]
gleam_stdlib = ">= 0.48.0 and < 2.0.0"
gleam_otp = ">= 0.14.0 and < 1.0.0"
gleam_erlang = ">= 0.34.0 and < 1.0.0"
gleam_time = ">= 1.0.0 and < 2.0.0"
vestibule = ">= 0.1.0 and < 1.0.0"

[dev-dependencies]
startest = ">= 0.8.0 and < 1.0.0"
```

Note: vestibule is not yet published to Hex. If not available, use a local path dependency:
```toml
vestibule = { path = "../../../vestibule" }
```

**Step 2: Create placeholder source file**

`server/levee_oauth/src/levee_oauth.gleam`:
```gleam
/// OAuth authentication for Levee using vestibule.
pub fn placeholder() {
  Nil
}
```

**Step 3: Create placeholder test file**

`server/levee_oauth/test/levee_oauth_test.gleam`:
```gleam
import startest
import startest/expect

pub fn main() {
  startest.run(startest.default_config())
}

pub fn placeholder_test() {
  levee_oauth.placeholder()
  |> expect.to_equal(Nil)
}
```

**Step 4: Build to verify package compiles**

Run: `cd server/levee_oauth && gleam build`
Expected: Successful build, dependencies downloaded.

**Step 5: Run tests**

Run: `cd server/levee_oauth && gleam test`
Expected: 1 test passes.

**Step 6: Commit**

```bash
git add server/levee_oauth/
git commit -m "feat(levee_oauth): create Gleam package skeleton

New levee_oauth package for vestibule-based OAuth.
Placeholder source and test files, dependencies configured."
```

---

### Task 2: Implement Error Types

**Files:**
- Create: `server/levee_oauth/src/levee_oauth/error.gleam`
- Test: `server/levee_oauth/test/levee_oauth_test.gleam`

**Step 1: Write the error module**

`server/levee_oauth/src/levee_oauth/error.gleam`:
```gleam
import vestibule/error as vestibule_error

/// OAuth errors for levee_oauth.
pub type OAuthError {
  /// Wraps a vestibule AuthError.
  VestibuleError(vestibule_error.AuthError(Nil))
  /// Required environment variable is missing.
  ConfigMissing(variable: String)
  /// Provider name not recognized.
  UnknownProvider(name: String)
  /// State store process is not available.
  StateStoreUnavailable
}
```

**Step 2: Verify it compiles**

Run: `cd server/levee_oauth && gleam check`
Expected: No errors.

**Step 3: Commit**

```bash
git add server/levee_oauth/src/levee_oauth/error.gleam
git commit -m "feat(levee_oauth): add OAuthError type

Wraps vestibule AuthError plus app-specific variants
for missing config, unknown provider, and store unavailability."
```

---

### Task 3: Implement Config Module

**Files:**
- Create: `server/levee_oauth/src/levee_oauth/config.gleam`
- Test: `server/levee_oauth/test/levee_oauth/config_test.gleam`

**Step 1: Write failing test**

`server/levee_oauth/test/levee_oauth/config_test.gleam`:
```gleam
import startest/expect

import levee_oauth/config
import levee_oauth/error

pub fn load_github_config_missing_client_id_test() {
  // With no env vars set, should fail with ConfigMissing
  // We can't easily unset env vars in tests, so test the
  // builder function instead
  let result = config.build_github_config("", "secret", "http://localhost/callback")
  result
  |> expect.to_be_error()
  |> expect.to_equal(error.ConfigMissing(variable: "GITHUB_CLIENT_ID"))
}

pub fn build_github_config_success_test() {
  let result = config.build_github_config(
    "my-client-id",
    "my-secret",
    "http://localhost:4000/auth/github/callback",
  )
  result
  |> expect.to_be_ok()
  // Just verify it returns Ok — the Config type is opaque from vestibule
}

pub fn build_github_config_missing_secret_test() {
  let result = config.build_github_config("id", "", "http://localhost/callback")
  result
  |> expect.to_be_error()
  |> expect.to_equal(error.ConfigMissing(variable: "GITHUB_CLIENT_SECRET"))
}

pub fn build_github_config_missing_redirect_test() {
  let result = config.build_github_config("id", "secret", "")
  result
  |> expect.to_be_error()
  |> expect.to_equal(error.ConfigMissing(variable: "GITHUB_REDIRECT_URI"))
}
```

**Step 2: Run test to verify it fails**

Run: `cd server/levee_oauth && gleam test`
Expected: Compilation error — `config` module doesn't exist.

**Step 3: Write the config module**

`server/levee_oauth/src/levee_oauth/config.gleam`:
```gleam
import gleam/erlang/os
import gleam/string

import vestibule/config as vestibule_config

import levee_oauth/error.{type OAuthError, ConfigMissing}

/// Load GitHub OAuth config from environment variables.
/// Reads GITHUB_CLIENT_ID, GITHUB_CLIENT_SECRET, GITHUB_REDIRECT_URI.
pub fn load_github_config() -> Result(vestibule_config.Config, OAuthError) {
  use client_id <- require_env("GITHUB_CLIENT_ID")
  use client_secret <- require_env("GITHUB_CLIENT_SECRET")
  use redirect_uri <- require_env("GITHUB_REDIRECT_URI")
  build_github_config(client_id, client_secret, redirect_uri)
}

/// Build a GitHub OAuth config from explicit values.
/// Validates that no values are empty strings.
pub fn build_github_config(
  client_id: String,
  client_secret: String,
  redirect_uri: String,
) -> Result(vestibule_config.Config, OAuthError) {
  case string.is_empty(client_id) {
    True -> Error(ConfigMissing(variable: "GITHUB_CLIENT_ID"))
    False ->
      case string.is_empty(client_secret) {
        True -> Error(ConfigMissing(variable: "GITHUB_CLIENT_SECRET"))
        False ->
          case string.is_empty(redirect_uri) {
            True -> Error(ConfigMissing(variable: "GITHUB_REDIRECT_URI"))
            False ->
              Ok(vestibule_config.new(client_id, client_secret, redirect_uri))
          }
      }
  }
}

fn require_env(
  name: String,
) -> fn(String) -> Result(vestibule_config.Config, OAuthError) {
  fn(next) {
    case os.get_env(name) {
      Ok(value) ->
        case string.is_empty(value) {
          True -> Error(ConfigMissing(variable: name))
          False -> next(value)
        }
      Error(Nil) -> Error(ConfigMissing(variable: name))
    }
  }
}
```

Wait — the `require_env` callback pattern won't work as written because the return type is wrong for `use`. Let me correct this:

`server/levee_oauth/src/levee_oauth/config.gleam`:
```gleam
import gleam/erlang/os
import gleam/result
import gleam/string

import vestibule/config as vestibule_config

import levee_oauth/error.{type OAuthError, ConfigMissing}

/// Load GitHub OAuth config from environment variables.
/// Reads GITHUB_CLIENT_ID, GITHUB_CLIENT_SECRET, GITHUB_REDIRECT_URI.
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
  Ok(vestibule_config.new(client_id, client_secret, redirect_uri))
}

fn require_env(name: String) -> Result(String, OAuthError) {
  case os.get_env(name) {
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
```

**Step 4: Run tests to verify they pass**

Run: `cd server/levee_oauth && gleam test`
Expected: All 4 config tests pass.

**Step 5: Commit**

```bash
git add server/levee_oauth/src/levee_oauth/config.gleam server/levee_oauth/test/levee_oauth/config_test.gleam
git commit -m "feat(levee_oauth): add config module

Loads GitHub OAuth config from environment variables.
Validates all required values are present and non-empty."
```

---

### Task 4: Implement State Store Actor

**Files:**
- Create: `server/levee_oauth/src/levee_oauth/state_store.gleam`
- Create: `server/levee_oauth/test/levee_oauth/state_store_test.gleam`

**Step 1: Write failing tests**

`server/levee_oauth/test/levee_oauth/state_store_test.gleam`:
```gleam
import gleam/erlang/process
import startest/expect

import levee_oauth/state_store

pub fn store_and_validate_test() {
  let assert Ok(actor) = state_store.start()
  let token = "test-state-token"

  state_store.store(actor, token, 180)

  // Should succeed and consume the token
  state_store.validate_and_consume(actor, token)
  |> expect.to_be_ok()

  // Second attempt should fail — token was consumed
  state_store.validate_and_consume(actor, token)
  |> expect.to_be_error()

  process.send(actor, state_store.Shutdown)
}

pub fn validate_unknown_token_test() {
  let assert Ok(actor) = state_store.start()

  state_store.validate_and_consume(actor, "nonexistent")
  |> expect.to_be_error()

  process.send(actor, state_store.Shutdown)
}

pub fn expired_token_test() {
  let assert Ok(actor) = state_store.start()
  let token = "expired-token"

  // Store with 0-second TTL (immediately expired)
  state_store.store(actor, token, 0)

  // Small delay to ensure expiry
  process.sleep(10)

  state_store.validate_and_consume(actor, token)
  |> expect.to_be_error()

  process.send(actor, state_store.Shutdown)
}
```

**Step 2: Run test to verify it fails**

Run: `cd server/levee_oauth && gleam test`
Expected: Compilation error — `state_store` module doesn't exist.

**Step 3: Write the state store**

`server/levee_oauth/src/levee_oauth/state_store.gleam`:
```gleam
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import gleam/time/timestamp

/// Messages the state store actor handles.
pub type Message {
  Store(token: String, ttl_seconds: Int)
  Validate(token: String, reply_to: Subject(Result(Nil, Nil)))
  Cleanup
  Shutdown
}

type State {
  State(tokens: Dict(String, Int), self: Subject(Message))
}

/// Default cleanup interval in milliseconds (60 seconds).
const cleanup_interval_ms = 60_000

/// Start the state store actor.
pub fn start() -> Result(Subject(Message), actor.StartError) {
  actor.start_spec(actor.Spec(
    init: fn() {
      let self = process.new_subject()
      let selector =
        process.new_selector()
        |> process.selecting(self, fn(msg) { msg })

      // Schedule first cleanup
      process.send_after(self, cleanup_interval_ms, Cleanup)

      actor.Ready(State(tokens: dict.new(), self: self), selector)
    },
    init_timeout: 1000,
    loop: handle_message,
  ))
}

/// Store a CSRF state token with a TTL in seconds.
pub fn store(actor: Subject(Message), token: String, ttl_seconds: Int) -> Nil {
  process.send(actor, Store(token: token, ttl_seconds: ttl_seconds))
}

/// Validate and consume a CSRF state token. Returns Ok(Nil) if valid,
/// Error(Nil) if not found or expired. Consumes the token on success.
pub fn validate_and_consume(
  actor: Subject(Message),
  token: String,
) -> Result(Nil, Nil) {
  process.call(actor, fn(reply_to) { Validate(token: token, reply_to: reply_to) }, 5000)
}

fn handle_message(message: Message, state: State) -> actor.Next(Message, State) {
  case message {
    Store(token:, ttl_seconds:) -> {
      let now = current_unix_seconds()
      let expires_at = now + ttl_seconds
      let new_tokens = dict.insert(state.tokens, token, expires_at)
      actor.continue(State(..state, tokens: new_tokens))
    }

    Validate(token:, reply_to:) -> {
      let now = current_unix_seconds()
      case dict.get(state.tokens, token) {
        Ok(expires_at) if expires_at > now -> {
          // Valid — consume it
          let new_tokens = dict.delete(state.tokens, token)
          process.send(reply_to, Ok(Nil))
          actor.continue(State(..state, tokens: new_tokens))
        }
        _ -> {
          // Not found or expired — clean up if expired
          let new_tokens = dict.delete(state.tokens, token)
          process.send(reply_to, Error(Nil))
          actor.continue(State(..state, tokens: new_tokens))
        }
      }
    }

    Cleanup -> {
      let now = current_unix_seconds()
      let new_tokens =
        dict.filter(state.tokens, fn(_token, expires_at) { expires_at > now })
      // Schedule next cleanup
      process.send_after(state.self, cleanup_interval_ms, Cleanup)
      actor.continue(State(..state, tokens: new_tokens))
    }

    Shutdown -> {
      actor.Stop(process.Normal)
    }
  }
}

fn current_unix_seconds() -> Int {
  timestamp.system_time()
  |> timestamp.to_unix_seconds()
}
```

Note: The `if` guard in the `case` may not be valid Gleam syntax. If so, replace with nested case:

```gleam
    Validate(token:, reply_to:) -> {
      let now = current_unix_seconds()
      case dict.get(state.tokens, token) {
        Ok(expires_at) -> {
          case expires_at > now {
            True -> {
              let new_tokens = dict.delete(state.tokens, token)
              process.send(reply_to, Ok(Nil))
              actor.continue(State(..state, tokens: new_tokens))
            }
            False -> {
              let new_tokens = dict.delete(state.tokens, token)
              process.send(reply_to, Error(Nil))
              actor.continue(State(..state, tokens: new_tokens))
            }
          }
        }
        Error(Nil) -> {
          process.send(reply_to, Error(Nil))
          actor.continue(state)
        }
      }
    }
```

**Step 4: Run tests to verify they pass**

Run: `cd server/levee_oauth && gleam test`
Expected: All 3 state store tests pass.

**Step 5: Commit**

```bash
git add server/levee_oauth/src/levee_oauth/state_store.gleam server/levee_oauth/test/levee_oauth/state_store_test.gleam
git commit -m "feat(levee_oauth): add CSRF state store Actor

OTP Actor storing state tokens with TTL-based expiry.
Tokens are consumed on validation (one-time use).
Periodic cleanup removes expired tokens every 60s."
```

---

### Task 5: Implement Main levee_oauth Module

**Files:**
- Modify: `server/levee_oauth/src/levee_oauth.gleam`
- Create: `server/levee_oauth/test/levee_oauth_test.gleam` (update)

**Step 1: Write the main module**

Replace `server/levee_oauth/src/levee_oauth.gleam`:
```gleam
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
import vestibule/strategy/github

import levee_oauth/config
import levee_oauth/error.{type OAuthError, StateStoreUnavailable, UnknownProvider, VestibuleError}
import levee_oauth/state_store

/// Default CSRF state TTL in seconds (3 minutes).
const state_ttl_seconds = 180

/// Phase 1: Begin OAuth flow. Returns the authorization URL to redirect to.
/// Stores CSRF state in the state store with a 3-minute TTL.
pub fn begin_auth(
  provider: String,
  store: Subject(state_store.Message),
) -> Result(String, OAuthError) {
  use strategy <- require_strategy(provider)
  use oauth_config <- result.try(config.load_github_config())

  case vestibule.authorize_url(strategy, oauth_config) {
    Ok(#(url, state)) -> {
      state_store.store(store, state, state_ttl_seconds)
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

  // Validate and consume CSRF state
  use _ <- result.try(
    state_store.validate_and_consume(store, state)
    |> result.replace_error(StateStoreUnavailable),
  )

  // Build callback params dict
  let callback_params =
    dict.from_list([#("code", code), #("state", state)])

  // Call vestibule to exchange code and fetch user
  case vestibule.handle_callback(strategy, oauth_config, callback_params, state) {
    Ok(auth) -> Ok(auth)
    Error(err) -> Error(VestibuleError(err))
  }
}

fn require_strategy(
  provider: String,
  next: fn(vestibule.Strategy(Nil)) -> Result(a, OAuthError),
) -> Result(a, OAuthError) {
  case provider {
    "github" -> next(github.strategy())
    _ -> Error(UnknownProvider(name: provider))
  }
}
```

Note: The `require_strategy` callback style uses Gleam's `use` pattern. The `vestibule.Strategy` type reference may need to be `vestibule/strategy.Strategy` — adjust imports based on what vestibule exports. Check `vestibule.gleam` re-exports vs direct module imports.

Looking at vestibule's source, `Strategy` is defined in `vestibule/strategy.gleam`, so the import should be:
```gleam
import vestibule/strategy.{type Strategy}
import vestibule/strategy/github
```

And the `require_strategy` signature becomes:
```gleam
fn require_strategy(
  provider: String,
  next: fn(Strategy(Nil)) -> Result(a, OAuthError),
) -> Result(a, OAuthError) {
```

**Step 2: Verify it compiles**

Run: `cd server/levee_oauth && gleam check`
Expected: No errors.

**Step 3: Update test file to remove placeholder**

Replace `server/levee_oauth/test/levee_oauth_test.gleam`:
```gleam
import startest

pub fn main() {
  startest.run(startest.default_config())
}

// Integration tests for begin_auth/complete_auth require
// real GitHub OAuth credentials and are tested via the
// Elixir e2e test suite. Unit tests for individual modules
// are in their respective test files.
```

**Step 4: Run all tests**

Run: `cd server/levee_oauth && gleam test`
Expected: All tests pass (config tests + state store tests).

**Step 5: Commit**

```bash
git add server/levee_oauth/src/levee_oauth.gleam server/levee_oauth/test/levee_oauth_test.gleam
git commit -m "feat(levee_oauth): implement begin_auth and complete_auth

Two-phase OAuth flow orchestration:
- begin_auth generates redirect URL, stores CSRF state (3-min TTL)
- complete_auth validates state, exchanges code via vestibule
- GitHub-only provider support via require_strategy pattern"
```

---

### Task 6: Wire levee_oauth into Mix Build

**Files:**
- Modify: `server/mix.exs:40-61` (deps), `server/mix.exs:82-83` (gleam_build)
- Modify: `server/lib/levee/application.ex:90` (load_gleam_modules)

**Step 1: Remove Ueberauth deps from mix.exs**

In `server/mix.exs`, remove these two lines from the `deps` function (lines 53-55):
```elixir
      # OAuth authentication
      {:ueberauth, "~> 0.10"},
      {:ueberauth_github, "~> 0.8"},
```

**Step 2: Add levee_oauth to gleam_build list**

In `server/mix.exs`, change line 82:
```elixir
    gleam_projects = ["levee_protocol", "levee_auth"]
```
to:
```elixir
    gleam_projects = ["levee_protocol", "levee_auth", "levee_oauth"]
```

**Step 3: Add levee_oauth to load_gleam_modules**

In `server/lib/levee/application.ex`, change line 90:
```elixir
    gleam_packages = ["levee_protocol", "levee_auth"]
```
to:
```elixir
    gleam_packages = ["levee_protocol", "levee_auth", "levee_oauth"]
```

**Step 4: Verify Gleam builds**

Run: `cd server && mix gleam.build`
Expected: All three Gleam packages compile.

**Step 5: Verify Mix compiles (expect warnings about missing Ueberauth)**

Run: `cd server && mix compile`
Expected: Compile succeeds. There may be warnings about the OAuthController referencing Ueberauth — that's fine, we'll fix it in Task 8.

**Step 6: Commit**

```bash
git add server/mix.exs server/lib/levee/application.ex
git commit -m "build: add levee_oauth to Gleam build, remove Ueberauth deps

Add levee_oauth to gleam_build and load_gleam_modules lists.
Remove ueberauth and ueberauth_github Mix dependencies."
```

---

### Task 7: Remove Ueberauth Configuration

**Files:**
- Modify: `server/config/config.exs:35-39`
- Modify: `server/config/runtime.exs:26-30`
- Modify: `server/config/test.exs:31-34`

**Step 1: Remove Ueberauth config from config.exs**

In `server/config/config.exs`, remove lines 35-39:
```elixir
# Configure Ueberauth for OAuth
config :ueberauth, Ueberauth,
  providers: [
    github: {Ueberauth.Strategy.Github, [default_scope: "user:email"]}
  ]
```

**Step 2: Replace Ueberauth config in runtime.exs with env var documentation**

In `server/config/runtime.exs`, replace lines 25-30:
```elixir
# Configure GitHub OAuth credentials from environment
if github_client_id = System.get_env("GITHUB_CLIENT_ID") do
  config :ueberauth, Ueberauth.Strategy.Github.OAuth,
    client_id: github_client_id,
    client_secret: System.get_env("GITHUB_CLIENT_SECRET")
end
```

with:
```elixir
# GitHub OAuth credentials are read directly from environment variables
# by the Gleam levee_oauth package:
#   GITHUB_CLIENT_ID - GitHub OAuth App client ID
#   GITHUB_CLIENT_SECRET - GitHub OAuth App client secret
#   GITHUB_REDIRECT_URI - Callback URL (e.g., http://localhost:4000/auth/github/callback)
```

**Step 3: Remove Ueberauth config from test.exs**

In `server/config/test.exs`, remove lines 31-34:
```elixir
# Disable ueberauth in tests (we mock the callbacks)
config :ueberauth, Ueberauth.Strategy.Github.OAuth,
  client_id: "test_client_id",
  client_secret: "test_client_secret"
```

**Step 4: Verify config compiles**

Run: `cd server && mix compile`
Expected: No config-related errors.

**Step 5: Commit**

```bash
git add server/config/config.exs server/config/runtime.exs server/config/test.exs
git commit -m "config: remove Ueberauth configuration

OAuth config now handled by levee_oauth Gleam package
reading GITHUB_CLIENT_ID, GITHUB_CLIENT_SECRET, GITHUB_REDIRECT_URI
directly from environment variables."
```

---

### Task 8: Start State Store in Supervision Tree

**Files:**
- Modify: `server/lib/levee/application.ex`

**Step 1: Add a GenServer wrapper for the state store**

We need an Elixir module that starts the Gleam actor and registers it under a known name so the controller can find it. Create a thin wrapper.

Add to `server/lib/levee/application.ex` — a new module is cleaner. Create `server/lib/levee/oauth/state_store_supervisor.ex`:

```elixir
defmodule Levee.OAuth.StateStoreSupervisor do
  @moduledoc """
  Starts and registers the Gleam OAuth state store actor.
  """
  use GenServer

  @compile {:no_warn_undefined, [:levee_oauth@state_store]}

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def get_actor do
    GenServer.call(__MODULE__, :get_actor)
  end

  @impl true
  def init(_) do
    case :levee_oauth@state_store.start() do
      {:ok, actor} -> {:ok, actor}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:get_actor, _from, actor) do
    {:reply, actor, actor}
  end
end
```

**Step 2: Add to supervision tree**

In `server/lib/levee/application.ex`, add `Levee.OAuth.StateStoreSupervisor` to the children list, before `LeveeWeb.Endpoint` (line 33). Add it after the `SessionStore` entry:

```elixir
          # In-memory user/session store (dev/test only, replaced by DB in prod)
          Levee.Auth.SessionStore,
          # OAuth CSRF state store (Gleam Actor)
          Levee.OAuth.StateStoreSupervisor,
          # DynamicSupervisor for document sessions
```

**Step 3: Verify it starts**

Run: `cd server && mix compile`
Expected: Compiles without errors.

**Step 4: Commit**

```bash
git add server/lib/levee/oauth/state_store_supervisor.ex server/lib/levee/application.ex
git commit -m "feat: add OAuth state store to supervision tree

Elixir GenServer wrapper starts the Gleam state_store Actor
and registers it for lookup by the OAuth controller."
```

---

### Task 9: Rewrite OAuthController

**Files:**
- Modify: `server/lib/levee_web/controllers/oauth_controller.ex`

**Step 1: Rewrite the controller**

Replace `server/lib/levee_web/controllers/oauth_controller.ex`:

```elixir
defmodule LeveeWeb.OAuthController do
  use LeveeWeb, :controller

  alias Levee.Auth.GleamBridge
  alias Levee.Auth.SessionStore

  @compile {:no_warn_undefined, [:levee_oauth]}

  @doc """
  Phase 1: Redirect the user to the OAuth provider's authorization page.
  """
  def request(conn, %{"provider" => provider}) do
    actor = Levee.OAuth.StateStoreSupervisor.get_actor()

    case :levee_oauth.begin_auth(provider, actor) do
      {:ok, url} ->
        redirect(conn, external: url)

      {:error, {:unknown_provider, _name}} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(404, Jason.encode!(%{error: %{code: "unknown_provider", message: "Unknown auth provider: #{provider}"}}))

      {:error, {:config_missing, variable}} ->
        require Logger
        Logger.error("OAuth not configured: missing #{variable}")

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(500, Jason.encode!(%{error: %{code: "oauth_not_configured", message: "OAuth is not configured"}}))

      {:error, reason} ->
        require Logger
        Logger.error("OAuth begin_auth failed: #{inspect(reason)}")

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(500, Jason.encode!(%{error: %{code: "oauth_error", message: "Failed to start authentication"}}))
    end
  end

  @doc """
  Phase 2: Handle the OAuth callback from the provider.
  Exchanges the code for user info, finds or creates the user, creates a session.
  """
  def callback(conn, %{"provider" => provider, "code" => code, "state" => state}) do
    actor = Levee.OAuth.StateStoreSupervisor.get_actor()

    case :levee_oauth.complete_auth(provider, code, state, actor) do
      {:ok, auth} ->
        handle_successful_auth(conn, auth)

      {:error, {:vestibule_error, :state_mismatch}} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{error: %{code: "state_mismatch", message: "Authentication failed, please try again"}}))

      {:error, {:vestibule_error, {:code_exchange_failed, _reason}}} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{error: %{code: "auth_failed", message: "Authentication failed, please try again"}}))

      {:error, {:vestibule_error, {:user_info_failed, _reason}}} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(502, Jason.encode!(%{error: %{code: "provider_error", message: "Could not fetch profile from provider"}}))

      {:error, :state_store_unavailable} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{error: %{code: "state_invalid", message: "Authentication failed, please try again"}}))

      {:error, reason} ->
        require Logger
        Logger.error("OAuth complete_auth failed: #{inspect(reason)}")

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{error: %{code: "auth_failed", message: "Authentication failed"}}))
    end
  end

  def callback(conn, %{"provider" => _provider, "error" => error_code} = params) do
    message = Map.get(params, "error_description", error_code)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{error: %{code: "oauth_failed", message: message}}))
  end

  defp handle_successful_auth(conn, auth) do
    # Extract fields from vestibule Auth record
    # Auth is a Gleam record: {:auth, uid, provider, info, credentials, extra}
    {_tag, uid, _provider, info, _credentials, _extra} = auth
    github_id = uid

    # Extract user info from vestibule UserInfo record
    # UserInfo: {:user_info, name, email, nickname, image, description, urls}
    {_tag, name, email, nickname, _image, _description, _urls} = info
    display_name = unwrap_option(name) || unwrap_option(nickname) || ""
    email_str = unwrap_option(email) || ""

    user =
      case SessionStore.find_user_by_github_id(github_id) do
        {:ok, existing_user} ->
          existing_user

        :error ->
          new_user = GleamBridge.create_oauth_user(email_str, display_name, github_id)

          # Auto-promote first user to admin
          new_user =
            if SessionStore.user_count() == 0 do
              Map.put(new_user, :is_admin, true)
            else
              new_user
            end

          SessionStore.store_user(new_user)
          new_user
      end

    session = GleamBridge.create_session(user.id, nil)
    SessionStore.store_session(session)

    redirect_url = get_redirect_url(conn, session.id)
    redirect(conn, external: redirect_url)
  end

  defp get_redirect_url(conn, token) do
    redirect_to = conn.params["redirect_url"] || "/admin"
    separator = if String.contains?(redirect_to, "?"), do: "&", else: "?"
    "#{redirect_to}#{separator}token=#{token}"
  end

  # Gleam Option type: {:some, value} or :none
  defp unwrap_option({:some, value}), do: value
  defp unwrap_option(:none), do: nil
end
```

**Important note:** The exact Gleam record tuple shapes for `Auth` and `UserInfo` must match what vestibule compiles to. The shapes shown above are based on the type definitions. Verify by running `iex -S mix` and inspecting the return value if the tuple destructuring doesn't work.

**Step 2: Remove Ueberauth `request` plug route handling**

The old controller used `plug Ueberauth` which auto-handled the `request` action. Our new controller explicitly handles both `request` and `callback`. The router already has both routes defined, so no router changes needed.

**Step 3: Verify it compiles**

Run: `cd server && mix compile`
Expected: Compiles without errors. May show warnings about unused Ueberauth aliases if any remain — check and remove.

**Step 4: Commit**

```bash
git add server/lib/levee_web/controllers/oauth_controller.ex
git commit -m "feat: rewrite OAuthController to use levee_oauth

Replace Ueberauth plug with direct calls to Gleam levee_oauth:
- request/2 calls begin_auth for redirect URL
- callback/2 calls complete_auth for code exchange
- Extracts user info from vestibule Auth record
- Preserves find-or-create user + auto-admin-promotion logic"
```

---

### Task 10: Clean Up and Verify

**Files:**
- Possibly modify: `server/mix.lock` (after deps.get)
- Remove any leftover Ueberauth references

**Step 1: Clean Mix deps**

Run: `cd server && mix deps.get`
Expected: Ueberauth packages are no longer fetched.

**Step 2: Run full compile**

Run: `cd server && mix compile --force`
Expected: Clean compile with no errors.

**Step 3: Search for any remaining Ueberauth references**

Run: `rg -i ueberauth server/lib/ server/config/ server/test/`
Expected: No results (or only in comments that should be cleaned up).

If any test files reference Ueberauth, update them to work with the new controller.

**Step 4: Run Gleam tests**

Run: `cd server/levee_oauth && gleam test`
Expected: All levee_oauth tests pass.

**Step 5: Run Elixir tests**

Run: `cd server && mix test`
Expected: Tests pass. If OAuth-specific tests exist that mock Ueberauth, they need updating (see Task 11).

**Step 6: Commit**

```bash
git add -A server/
git commit -m "chore: clean up Ueberauth removal

Remove remaining Ueberauth references, update mix.lock,
verify clean compile across Gleam and Elixir."
```

---

### Task 11: Update Existing OAuth Tests (if any)

**Files:**
- Check: `server/test/levee_web/controllers/oauth_controller_test.exs`

**Step 1: Check if OAuth controller tests exist**

Run: `ls server/test/levee_web/controllers/oauth_controller_test.exs 2>/dev/null`

If the file exists, it likely mocks Ueberauth assigns (`ueberauth_auth`, `ueberauth_failure`). These tests need to be rewritten to either:
- Set environment variables and test the full flow (integration test)
- Mock the `:levee_oauth` module calls
- Test the controller's error handling branches

If no test file exists, create a basic one that tests error paths:

```elixir
defmodule LeveeWeb.OAuthControllerTest do
  use LeveeWeb.ConnCase

  describe "request/2" do
    test "returns 404 for unknown provider", %{conn: conn} do
      conn = get(conn, "/auth/unknown")
      assert json_response(conn, 404)["error"]["code"] == "unknown_provider"
    end
  end

  describe "callback/2" do
    test "returns 401 when provider returns error", %{conn: conn} do
      conn = get(conn, "/auth/github/callback", %{
        "provider" => "github",
        "error" => "access_denied",
        "error_description" => "User denied access"
      })
      assert json_response(conn, 401)["error"]["code"] == "oauth_failed"
    end
  end
end
```

**Step 2: Run tests**

Run: `cd server && mix test test/levee_web/controllers/oauth_controller_test.exs`
Expected: Tests pass.

**Step 3: Commit**

```bash
git add server/test/
git commit -m "test: update OAuth controller tests for vestibule

Replace Ueberauth-based test mocks with levee_oauth error path tests."
```

---

### Task 12: Manual Integration Test

This task is not automatable — it requires GitHub OAuth credentials.

**Step 1: Set environment variables**

```bash
export GITHUB_CLIENT_ID="your-github-oauth-app-client-id"
export GITHUB_CLIENT_SECRET="your-github-oauth-app-client-secret"
export GITHUB_REDIRECT_URI="http://localhost:4000/auth/github/callback"
```

**Step 2: Start the server**

Run: `cd server && mix phx.server`
Expected: Server starts on port 4000 with no errors.

**Step 3: Test the OAuth flow**

1. Navigate to `http://localhost:4000/admin`
2. Click "Sign in with GitHub"
3. Authorize on GitHub
4. Should redirect back to `/admin?token=...`
5. Should see admin dashboard (logged in)

**Step 4: Verify state validation**

Try hitting the callback URL directly with a fake state parameter:
```bash
curl -v "http://localhost:4000/auth/github/callback?code=fake&state=fake"
```
Expected: 401 response with state_invalid or auth_failed error.

**Step 5: Final commit**

```bash
git commit --allow-empty -m "test: verify manual OAuth flow with vestibule

Manual integration test passed:
- GitHub OAuth redirect works
- Callback creates user and session
- CSRF state validation rejects invalid state"
```
