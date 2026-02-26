# Replace Ueberauth with Vestibule for OAuth

## Goal

Replace the Elixir Ueberauth OAuth dependency with vestibule (Gleam-native OAuth library) to keep authentication logic in the Gleam ecosystem. Introduce a new `levee_oauth` Gleam package that owns the OAuth flow orchestration, with a thin Phoenix controller handling HTTP transport.

## Context

Levee currently uses Ueberauth (Elixir) for GitHub OAuth login in the admin UI. Vestibule is a strategy-based OAuth2 library for Gleam with a built-in GitHub strategy, CSRF state management, and normalized user data. Moving to vestibule aligns with the project's direction of keeping core logic in Gleam.

The admin UI login page already navigates to `/auth/github` — no frontend changes needed.

## Architecture: New `levee_oauth` Package

### Package Structure

```
server/levee_oauth/
├── gleam.toml
├── src/
│   ├── levee_oauth.gleam              # Public API: begin_auth, complete_auth
│   └── levee_oauth/
│       ├── state_store.gleam          # OTP Actor for CSRF state tokens
│       ├── config.gleam               # Load OAuth config from env vars
│       └── error.gleam                # OAuthError type
└── test/
    └── levee_oauth_test.gleam
```

### Dependencies

- `vestibule` — OAuth strategy, authorize URL, callback handling
- `levee_auth` — user types (not called directly; Auth result returned to caller)
- `gleam_otp` — Actor for state store
- `gleam_erlang` — process utilities
- `gleam_time` — timestamp for TTL

### Why a Separate Package

Follows the existing pattern (`levee_protocol`, `levee_auth`). Keeps vestibule's HTTP dependencies (`gleam_httpc`) out of `levee_auth`, which currently does no HTTP. Clean separation of concerns — `levee_auth` owns primitives (passwords, JWTs, users, sessions), `levee_oauth` owns the OAuth flow.

## Public API

### `levee_oauth.begin_auth(provider, state_store)`

Phase 1 of OAuth flow.

- Loads config from environment via `config.load_github_config()`
- Calls `vestibule.authorize_url(strategy, config)` to get redirect URL and CSRF state
- Stores state token in state_store Actor with 3-minute TTL
- Returns `Result(String, OAuthError)` — the redirect URL

### `levee_oauth.complete_auth(provider, code, state, state_store)`

Phase 2 of OAuth flow.

- Validates and consumes CSRF state from store (one-time use)
- Calls `vestibule.handle_callback(strategy, config, callback_params, expected_state)`
- Returns `Result(vestibule.Auth, OAuthError)` — normalized auth result with uid, provider, user info, and credentials

The caller (Phoenix controller) is responsible for user find-or-create and session management using the returned `Auth` value.

## State Store Actor

A `gleam_otp/actor` process storing CSRF state tokens with automatic expiry.

- **State:** `Dict(String, Int)` mapping state token to expiry timestamp (unix seconds)
- **Messages:**
  - `Store(token, ttl_seconds)` — insert token with expiry
  - `Validate(token, reply_to)` — check existence + expiry, delete if valid, reply with Result
  - `Cleanup` — remove expired tokens (self-scheduled every 60 seconds)
- **TTL:** 3 minutes
- **Cleanup interval:** 60 seconds
- **Supervision:** Child of levee's OTP application supervision tree

No persistence — if the server restarts mid-flow, the user clicks "Sign in with GitHub" again.

## Config

OAuth credentials loaded from environment variables:

| Variable | Purpose |
|----------|---------|
| `GITHUB_CLIENT_ID` | GitHub OAuth App client ID |
| `GITHUB_CLIENT_SECRET` | GitHub OAuth App client secret |
| `GITHUB_REDIRECT_URI` | Callback URL (e.g., `http://localhost:4000/auth/github/callback`) |

`config.load_github_config()` returns `Result(vestibule.Config, OAuthError)`. Fails with `ConfigMissing` if any variable is unset.

Unlike Ueberauth, which auto-derived the redirect URI from Phoenix routing, vestibule requires it explicitly.

## Error Handling

```gleam
type OAuthError {
  VestibuleError(vestibule.AuthError)
  ConfigMissing(variable: String)
  UnknownProvider(name: String)
  StateStoreUnavailable
}
```

Phoenix controller maps errors to HTTP responses:

| Error | HTTP | User message |
|-------|------|--------------|
| StateMismatch (via vestibule) | 401 | "Authentication failed, please try again" |
| CodeExchangeFailed | 401 | "Authentication failed, please try again" |
| UserInfoFailed | 502 | "Could not fetch profile from provider" |
| ConfigMissing | 500 | "OAuth not configured" (detail logged) |
| UnknownProvider | 404 | "Unknown auth provider" |

## Request Flow

```
Browser → GET /auth/github
  → OAuthController.request/2
  → :levee_oauth.begin_auth("github", state_store)
    → vestibule.authorize_url(strategy, config)
    → state_store ! Store(state, 180)
  → redirect to GitHub

GitHub → GET /auth/github/callback?code=X&state=Y
  → OAuthController.callback/2
  → :levee_oauth.complete_auth("github", code, state, state_store)
    → state_store ! Validate(state) → Ok/Error
    → vestibule.handle_callback(strategy, config, params, state)
    → returns Auth{uid, info, credentials}
  → controller: find/create user via GleamBridge + SessionStore
  → controller: create session
  → redirect to /admin?token=session_id
```

## Files Changed

### New

| File | Purpose |
|------|---------|
| `server/levee_oauth/gleam.toml` | Package config and dependencies |
| `server/levee_oauth/src/levee_oauth.gleam` | Public API |
| `server/levee_oauth/src/levee_oauth/state_store.gleam` | CSRF state Actor |
| `server/levee_oauth/src/levee_oauth/config.gleam` | Env var config loader |
| `server/levee_oauth/src/levee_oauth/error.gleam` | Error types |
| `server/levee_oauth/test/levee_oauth_test.gleam` | Tests |

### Modified

| File | Change |
|------|--------|
| `server/mix.exs` | Remove `:ueberauth`, `:ueberauth_github` deps. Add `"levee_oauth"` to `gleam_build` list. |
| `server/config/*.exs` | Remove Ueberauth configuration |
| `server/lib/levee/application.ex` | Start state_store Actor in supervision tree |
| `server/lib/levee_web/controllers/oauth_controller.ex` | Rewrite: drop `plug Ueberauth`, call `:levee_oauth` functions |

### Unchanged

| File | Why |
|------|-----|
| `server/lib/levee_web/router.ex` | `/auth/:provider` routes stay the same |
| `server/levee_auth/` | No changes — user/session primitives unchanged |
| `server/levee_admin/` | Login page already navigates to `/auth/github` |
| `server/lib/levee/auth/gleam_bridge.ex` | `create_oauth_user/3` stays |
| `server/lib/levee/auth/session_store.ex` | `find_user_by_github_id/1` stays |

## Future: Extract to Vestibule

The state store and begin/complete orchestration in `levee_oauth` are generic — every vestibule consumer needs them. Once proven in levee, extract `state_store.gleam` and the orchestration functions into vestibule itself. The module boundaries drawn here make that extraction mechanical.

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Separate package vs. in levee_auth | Separate `levee_oauth` | Keeps HTTP deps out of levee_auth; follows existing pattern |
| State storage | Gleam Actor | Gleam-native; no Elixir dependency for OAuth state |
| State TTL | 3 minutes | Enough for redirect + login + callback |
| GitHub only | Yes | Only provider vestibule supports; strategy pattern makes adding more trivial |
| Phoenix forwards to Gleam | Yes | One port, Phoenix handles HTTP transport, Gleam owns logic |
| Explicit redirect URI | Env var | No magic derivation; clear configuration |
