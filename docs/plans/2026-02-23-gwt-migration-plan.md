# gwt JWT Migration Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the hand-rolled Gleam JWT module and Elixir JOSE library with the `gwt` Gleam package, making Gleam the single source of truth for all JWT operations.

**Architecture:** The Gleam `levee_auth` package handles all JWT signing and verification via `gwt`. The Elixir `Levee.Auth.JWT` module becomes a thin wrapper that delegates to Gleam through `Levee.Auth.GleamBridge`. The auth plug, protocol bridge, and channel code are unchanged.

**Tech Stack:** Gleam (gwt v2.x), Elixir (Phoenix), BEAM

**Design doc:** `docs/plans/2026-02-23-gwt-migration-design.md`

---

### Task 1: Add gwt dependency and delete hand-rolled jwt.gleam

**Files:**
- Modify: `server/levee_auth/gleam.toml`
- Delete: `server/levee_auth/src/jwt.gleam`

**Step 1: Update gleam.toml dependencies**

In `server/levee_auth/gleam.toml`, add `gwt` and remove `gleam_crypto`:

```toml
[dependencies]
gleam_stdlib = ">= 0.44.0 and < 1.0.0"
gleam_json = ">= 3.0.0 and < 4.0.0"
gleam_time = ">= 1.0.0 and < 2.0.0"
youid = ">= 1.0.0 and < 2.0.0"
gwt = ">= 2.0.0 and < 3.0.0"

[dev-dependencies]
gleeunit = ">= 1.0.0 and < 2.0.0"
```

**Step 2: Delete the hand-rolled JWT module**

```bash
rm server/levee_auth/src/jwt.gleam
```

**Step 3: Verify the dependency resolves**

```bash
cd server/levee_auth && gleam deps download
```

Expected: Dependencies download successfully, no errors.

**Step 4: Commit**

```bash
git add server/levee_auth/gleam.toml server/levee_auth/src/jwt.gleam
git commit -m "refactor(auth): remove hand-rolled jwt.gleam, add gwt dependency"
```

---

### Task 2: Rewrite token.gleam to use gwt

**Files:**
- Modify: `server/levee_auth/src/token.gleam`

**Step 1: Rewrite token.gleam**

Replace the full contents of `server/levee_auth/src/token.gleam` with:

```gleam
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
    |> gwt.set_subject(to: claims.user_id)
    |> gwt.set_issuer(to: "levee")
    |> gwt.set_issued_at(to: claims.iat)
    |> gwt.set_expiration(to: claims.exp)
    |> gwt.set_payload_claim(set: "tenant_id", to: json.string(claims.tenant_id))
    |> gwt.set_payload_claim(
      set: "document_id",
      to: json.string(claims.document_id),
    )
    |> gwt.set_payload_claim(set: "scopes", to: json.string(scopes_str))

  let builder = case claims.token_id {
    Some(id) -> gwt.set_jwt_id(builder, to: id)
    None -> builder
  }

  gwt.to_signed_string(builder, gwt.HS256, secret: config.secret)
}

/// Verify a JWT token and extract claims.
pub fn verify(token: String, secret: String) -> Result(TokenClaims, TokenError) {
  use jwt <- result.try(
    gwt.from_signed_string(token, secret: secret)
    |> result.map_error(map_gwt_error),
  )

  let now = now_unix()

  // Extract standard claims
  use user_id <- result.try(
    gwt.get_subject(from: jwt)
    |> result.map_error(map_gwt_error),
  )

  use iat <- result.try(
    gwt.get_issued_at(from: jwt)
    |> result.map_error(map_gwt_error),
  )

  use exp <- result.try(
    gwt.get_expiration(from: jwt)
    |> result.map_error(map_gwt_error),
  )

  // Check expiration
  case exp < now {
    True -> Error(TokenExpired)
    False -> {
      // Extract custom claims
      use tenant_id <- result.try(
        gwt.get_payload_claim(
          from: jwt,
          claim: "tenant_id",
          decoder: decode.string,
        )
        |> result.map_error(map_gwt_error),
      )

      use document_id <- result.try(
        gwt.get_payload_claim(
          from: jwt,
          claim: "document_id",
          decoder: decode.string,
        )
        |> result.map_error(map_gwt_error),
      )

      use scopes_str <- result.try(
        gwt.get_payload_claim(
          from: jwt,
          claim: "scopes",
          decoder: decode.string,
        )
        |> result.map_error(map_gwt_error),
      )

      let parsed_scopes =
        scopes_str
        |> string.split(",")
        |> list.filter(fn(s) { s != "" })
        |> scopes.list_from_strings()

      let token_id = case gwt.get_jwt_id(from: jwt) {
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
  }
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

fn map_gwt_error(error: gwt.JwtDecodeError) -> TokenError {
  case error {
    gwt.InvalidSignature -> InvalidSignature
    gwt.TokenExpired -> TokenExpired
    gwt.TokenNotValidYet -> TokenNotYetValid
    gwt.MissingClaim -> MissingClaims
    _ -> MalformedToken
  }
}
```

**Step 2: Check that Gleam compiles**

```bash
cd server/levee_auth && gleam check
```

Expected: Compiles with no errors. If there are API mismatches with gwt, adjust the
`gwt.*` calls to match exact signatures.

**Step 3: Build Gleam**

```bash
cd server/levee_auth && gleam build
```

Expected: Builds successfully.

**Step 4: Commit**

```bash
git add server/levee_auth/src/token.gleam
git commit -m "refactor(auth): rewrite token.gleam to use gwt library"
```

---

### Task 3: Add Gleam token tests

**Files:**
- Create: `server/levee_auth/test/token_test.gleam`

**Step 1: Write token tests**

Create `server/levee_auth/test/token_test.gleam`:

```gleam
import gleam/option.{None, Some}
import gleeunit/should
import scopes
import token.{TokenClaims, TokenConfig}

const test_secret = "test-secret-key-for-testing"

fn test_config() -> TokenConfig {
  token.default_config(test_secret)
}

fn test_claims() -> TokenClaims {
  TokenClaims(
    user_id: "user-1",
    tenant_id: "tenant-1",
    document_id: "doc-1",
    scopes: scopes.read_write(),
    iat: 1_700_000_000,
    exp: 1_700_007_200,
    token_id: None,
  )
}

pub fn create_and_verify_round_trip_test() {
  let claims = test_claims()
  let config = test_config()
  let jwt = token.create(claims, config)

  let result = token.verify(jwt, test_secret)
  should.be_ok(result)

  let assert Ok(decoded) = result
  should.equal(decoded.user_id, "user-1")
  should.equal(decoded.tenant_id, "tenant-1")
  should.equal(decoded.document_id, "doc-1")
  should.equal(decoded.scopes, scopes.read_write())
  should.equal(decoded.iat, 1_700_000_000)
  should.equal(decoded.exp, 1_700_007_200)
}

pub fn create_with_token_id_test() {
  let claims =
    TokenClaims(..test_claims(), token_id: Some("unique-jti-123"))
  let config = test_config()
  let jwt = token.create(claims, config)

  let assert Ok(decoded) = token.verify(jwt, test_secret)
  should.equal(decoded.token_id, Some("unique-jti-123"))
}

pub fn verify_wrong_secret_test() {
  let jwt = token.create(test_claims(), test_config())

  let result = token.verify(jwt, "wrong-secret")
  should.be_error(result)

  let assert Error(token.InvalidSignature) = result
}

pub fn verify_tampered_token_test() {
  let jwt = token.create(test_claims(), test_config())

  let result = token.verify(jwt <> "x", "wrong-secret")
  should.be_error(result)
}

pub fn verify_expired_token_test() {
  let claims =
    TokenClaims(..test_claims(), iat: 1_000_000_000, exp: 1_000_000_001)
  let jwt = token.create(claims, test_config())

  let result = token.verify(jwt, test_secret)
  should.be_error(result)

  let assert Error(token.TokenExpired) = result
}

pub fn create_document_token_test() {
  let config = test_config()
  let jwt =
    token.create_document_token(
      "user-1",
      "tenant-1",
      "doc-1",
      scopes.full_access(),
      config,
    )

  let assert Ok(decoded) = token.verify(jwt, test_secret)
  should.equal(decoded.user_id, "user-1")
  should.equal(decoded.tenant_id, "tenant-1")
  should.equal(decoded.document_id, "doc-1")
  should.equal(decoded.scopes, scopes.full_access())
}

pub fn has_scope_test() {
  let claims = test_claims()
  should.be_true(token.has_scope(claims, scopes.DocRead))
  should.be_true(token.has_scope(claims, scopes.DocWrite))
  should.be_false(token.has_scope(claims, scopes.SummaryRead))
}

pub fn is_expired_with_future_exp_test() {
  // Claims with exp far in the future
  let claims = TokenClaims(..test_claims(), exp: 9_999_999_999)
  should.be_false(token.is_expired(claims))
}

pub fn is_expired_with_past_exp_test() {
  // Claims with exp in the past
  let claims = TokenClaims(..test_claims(), exp: 1)
  should.be_true(token.is_expired(claims))
}

pub fn read_only_claims_test() {
  let claims =
    token.read_only_claims("user-1", "tenant-1", "doc-1", test_config())
  should.equal(claims.scopes, scopes.read_only())
}

pub fn full_access_claims_test() {
  let claims =
    token.full_access_claims("user-1", "tenant-1", "doc-1", test_config())
  should.equal(claims.scopes, scopes.full_access())
}
```

**Step 2: Run Gleam tests**

```bash
cd server/levee_auth && gleam test
```

Expected: All tests pass.

**Step 3: Commit**

```bash
git add server/levee_auth/test/token_test.gleam
git commit -m "test(auth): add Gleam token tests for gwt-based implementation"
```

---

### Task 4: Simplify Elixir JWT module to delegate to Gleam bridge

**Files:**
- Modify: `server/lib/levee/auth/jwt.ex`

**Step 1: Rewrite jwt.ex to delegate to GleamBridge**

Replace the full contents of `server/lib/levee/auth/jwt.ex` with:

```elixir
defmodule Levee.Auth.JWT do
  @moduledoc """
  JWT signing and verification for Fluid Framework authentication.

  Delegates all JWT operations to the Gleam levee_auth package via GleamBridge.
  """

  alias Levee.Auth.GleamBridge
  alias Levee.Auth.TenantSecrets

  require Logger

  # Standard permission scopes
  @scope_doc_read "doc:read"
  @scope_doc_write "doc:write"
  @scope_summary_write "summary:write"

  # Token version
  @token_version "1.0"

  # Default expiration: 1 hour
  @default_expiration_seconds 3600

  @type token_claims :: %{
          required(:documentId) => String.t(),
          required(:scopes) => [String.t()],
          required(:tenantId) => String.t(),
          required(:user) => %{required(:id) => String.t()},
          required(:iat) => integer(),
          required(:exp) => integer(),
          required(:ver) => String.t(),
          optional(:jti) => String.t()
        }

  @doc """
  Returns the standard permission scopes.
  """
  def scope_doc_read, do: @scope_doc_read
  def scope_doc_write, do: @scope_doc_write
  def scope_summary_write, do: @scope_summary_write

  @doc """
  Signs a JWT token for the given claims and tenant.

  Delegates to Gleam's token module via GleamBridge.
  """
  @spec sign(token_claims(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def sign(claims, tenant_id) do
    case TenantSecrets.get_secret(tenant_id) do
      {:ok, secret} ->
        user_id = get_in(claims, [:user, :id]) || ""
        document_id = Map.get(claims, :documentId, "")
        tenant = Map.get(claims, :tenantId, tenant_id)

        scopes =
          claims
          |> Map.get(:scopes, [])
          |> Enum.map(&scope_string_to_gleam/1)

        token = GleamBridge.create_document_token(user_id, tenant, document_id, scopes, secret)
        {:ok, token}

      {:error, reason} ->
        {:error, {:tenant_secret_not_found, reason}}
    end
  end

  @doc """
  Verifies a JWT token and returns the claims.

  Delegates to Gleam's token module via GleamBridge.
  """
  @spec verify(String.t(), String.t()) :: {:ok, token_claims()} | {:error, term()}
  def verify(token, tenant_id) do
    case TenantSecrets.get_secret(tenant_id) do
      {:ok, secret} ->
        case GleamBridge.verify_token(token, secret) do
          {:ok, gleam_claims} ->
            {:ok, gleam_claims_to_elixir(gleam_claims)}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, {:tenant_secret_not_found, reason}}
    end
  end

  @doc """
  Generates a token for testing purposes.
  """
  @spec generate_test_token(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def generate_test_token(tenant_id, document_id, user_id, opts \\ []) do
    scopes = Keyword.get(opts, :scopes, [@scope_doc_read, @scope_doc_write])
    expires_in = Keyword.get(opts, :expires_in, @default_expiration_seconds)
    jti = Keyword.get(opts, :jti, generate_jti())

    now = System.system_time(:second)

    claims = %{
      documentId: document_id,
      scopes: scopes,
      tenantId: tenant_id,
      user: %{id: user_id},
      iat: now,
      exp: now + expires_in,
      ver: @token_version,
      jti: jti
    }

    sign(claims, tenant_id)
  end

  @doc """
  Generates a read-only token for testing.
  """
  @spec generate_read_only_token(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def generate_read_only_token(tenant_id, document_id, user_id, opts \\ []) do
    opts = Keyword.put(opts, :scopes, [@scope_doc_read])
    generate_test_token(tenant_id, document_id, user_id, opts)
  end

  @doc """
  Generates a token with all scopes (read, write, summary).
  """
  @spec generate_full_access_token(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def generate_full_access_token(tenant_id, document_id, user_id, opts \\ []) do
    opts = Keyword.put(opts, :scopes, [@scope_doc_read, @scope_doc_write, @scope_summary_write])
    generate_test_token(tenant_id, document_id, user_id, opts)
  end

  @doc """
  Checks if the given claims have expired.
  """
  @spec expired?(token_claims()) :: boolean()
  def expired?(claims) do
    current_time = System.system_time(:second)
    Map.get(claims, :exp, 0) < current_time
  end

  @doc """
  Checks if the claims have the required scope.
  """
  @spec has_scope?(token_claims(), String.t()) :: boolean()
  def has_scope?(claims, required_scope) do
    scopes = Map.get(claims, :scopes, [])
    required_scope in scopes
  end

  @doc """
  Checks if the claims have read permission.
  """
  @spec has_read_scope?(token_claims()) :: boolean()
  def has_read_scope?(claims), do: has_scope?(claims, @scope_doc_read)

  @doc """
  Checks if the claims have write permission.
  """
  @spec has_write_scope?(token_claims()) :: boolean()
  def has_write_scope?(claims), do: has_scope?(claims, @scope_doc_write)

  @doc """
  Checks if the claims have summary write permission.
  """
  @spec has_summary_write_scope?(token_claims()) :: boolean()
  def has_summary_write_scope?(claims), do: has_scope?(claims, @scope_summary_write)

  # Private functions

  defp generate_jti do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  # Convert Gleam claims map to the Elixir token_claims format
  defp gleam_claims_to_elixir(gleam_claims) do
    scopes =
      gleam_claims.scopes
      |> Enum.map(&scope_gleam_to_string/1)

    %{
      documentId: gleam_claims.document_id,
      scopes: scopes,
      tenantId: gleam_claims.tenant_id,
      user: %{id: gleam_claims.user_id},
      iat: gleam_claims.iat,
      exp: gleam_claims.exp,
      ver: @token_version,
      jti: gleam_claims.token_id
    }
  end

  # Convert scope string to Gleam scope atom
  # Gleam Scope constructors compile to atoms on BEAM
  @compile {:no_warn_undefined, [:scopes]}
  defp scope_string_to_gleam(scope_str) do
    case scope_str do
      "doc:read" -> :doc_read
      "doc:write" -> :doc_write
      "summary:read" -> :summary_read
      "summary:write" -> :summary_write
      other -> other
    end
  end

  # Convert Gleam scope atom to string
  defp scope_gleam_to_string(scope) do
    case scope do
      :doc_read -> "doc:read"
      :doc_write -> "doc:write"
      :summary_read -> "summary:read"
      :summary_write -> "summary:write"
      other when is_binary(other) -> other
      _ -> inspect(scope)
    end
  end
end
```

**Important note:** The Gleam `Scope` type variants (`DocRead`, `DocWrite`, etc.)
compile to BEAM atoms (`doc_read`, `doc_write`, etc.). The `sign/2` function must
convert string scopes to these atoms before passing to Gleam, and `verify/2` must
convert them back. If the Gleam representation differs (e.g. tuple-tagged), adjust
the `scope_string_to_gleam` and `scope_gleam_to_string` functions accordingly.

**Step 2: Verify it compiles**

```bash
cd server && mix compile --force
```

Expected: Compiles with no errors. Watch for warnings about undefined atoms.

**Step 3: Commit**

```bash
git add server/lib/levee/auth/jwt.ex
git commit -m "refactor(auth): simplify JWT module to delegate to Gleam bridge"
```

---

### Task 5: Remove JOSE dependency from mix.exs

**Files:**
- Modify: `server/mix.exs`

**Step 1: Remove jose from deps**

In `server/mix.exs`, remove the line:

```elixir
{:jose, "~> 1.11"},
```

And remove the comment above it (`# JWT authentication`).

**Step 2: Clean and recompile**

```bash
cd server && mix deps.clean jose && mix deps.get && mix compile --force
```

Expected: Compiles with no errors. If any module still references JOSE, fix it.

**Step 3: Commit**

```bash
git add server/mix.exs server/mix.lock
git commit -m "refactor(auth): remove jose dependency, JWT now handled by Gleam gwt"
```

---

### Task 6: Run the full test suite and fix issues

**Files:**
- Possibly modify: `server/lib/levee/auth/jwt.ex`, `server/lib/levee/auth/gleam_bridge.ex`

**Step 1: Run Gleam tests**

```bash
cd server/levee_auth && gleam test
```

Expected: All pass.

**Step 2: Build Gleam and force-reload BEAM modules**

```bash
cd server && mix cmd --cd levee_auth gleam build && mix compile --force
```

**Step 3: Run Elixir JWT tests**

```bash
cd server && mix test test/levee/auth/jwt_test.exs --trace
```

Expected: All 16 tests pass. If failures occur:

- **Scope format mismatch**: The Gleam `Scope` type compiles to BEAM atoms. Check
  if `gleam_claims_to_elixir` correctly converts them. You may need to inspect the
  raw return value from `GleamBridge.verify_token` to see the actual BEAM
  representation of scopes.

- **Claims field mapping**: The GleamBridge `gleam_claims_to_map` returns
  `%{user_id:, tenant_id:, document_id:, ...}`. The new `gleam_claims_to_elixir`
  in jwt.ex must map these to `%{documentId:, tenantId:, user: %{id:}, ...}`.

**Step 4: Run auth plug tests**

```bash
cd server && mix test test/levee_web/plugs/auth_test.exs --trace
```

Expected: All pass.

**Step 5: Run channel tests**

```bash
cd server && mix test test/levee_web/channels/ --trace
```

Expected: All pass.

**Step 6: Run full test suite**

```bash
cd server && mix test
```

Expected: All tests pass.

**Step 7: Commit any fixes**

```bash
git add -A && git commit -m "fix(auth): adjust JWT bridge for gwt compatibility"
```

(Only if fixes were needed.)

---

### Task 7: Final cleanup and format

**Files:**
- Various formatting

**Step 1: Format Gleam code**

```bash
cd server/levee_auth && gleam format
```

**Step 2: Format Elixir code**

```bash
cd server && mix format
```

**Step 3: Run full test suite one final time**

```bash
cd server && mix test
```

Expected: All pass.

**Step 4: Commit formatting**

```bash
git add -A && git commit -m "style: format after gwt migration"
```

(Only if formatting changes exist.)

---

## Debugging Reference

### Gleam Scope BEAM Representation

Gleam custom type constructors compile to atoms or tagged tuples on BEAM. To check
how `Scope` variants look in Elixir:

```elixir
# In iex
:scopes.to_string(:doc_read)  # Should return "doc:read"
```

If scopes are tagged tuples (e.g. `{:doc_read}`) rather than bare atoms, update
the `scope_string_to_gleam` and `scope_gleam_to_string` functions.

### GleamBridge Claims Format

The bridge's `gleam_claims_to_map` destructures the Gleam `TokenClaims` record
tuple. After the gwt migration, verify the tuple shape hasn't changed:

```elixir
# The Gleam TokenClaims compiles to:
{:token_claims, user_id, tenant_id, document_id, scopes, iat, exp, token_id}
```

If the field order changed, update the pattern match in
`gleam_bridge.ex:gleam_claims_to_map/1`.
