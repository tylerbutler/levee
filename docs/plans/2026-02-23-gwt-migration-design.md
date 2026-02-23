# Replace Hand-Rolled JWT with gwt Library

## Goal

Consolidate the dual JWT implementation (Elixir JOSE + hand-rolled Gleam) into a
single Gleam implementation using the [gwt](https://hex.pm/packages/gwt) library.
Gleam becomes the single source of truth for all JWT operations. The Elixir auth
plug and `Levee.Auth.JWT` module become thin wrappers calling Gleam via the
existing bridge pattern.

## Decisions

- **Auth plug stays in Elixir** — it's Phoenix-native; all JWT operations route
  through Gleam via the bridge.
- **TenantSecrets GenServer stays in Elixir** — it's infrastructure, not JWT logic.
- **Approach: Replace-and-Bridge** — replace both hand-rolled Gleam JWT and Elixir
  JOSE with gwt in a single changeset.

## Architecture

```
HTTP Request
  → LeveeWeb.Plugs.Auth (Elixir, unchanged)
    → Levee.Auth.JWT.verify/2 (Elixir, now delegates to bridge)
      → Levee.Auth.GleamBridge.verify_token/2
        → token.verify/2 (Gleam, now uses gwt)
          → gwt.from_signed_string/2
    → Levee.Protocol.Bridge.validate_claims_* (unchanged)
      → levee_protocol/jwt.gleam (unchanged, operates on decoded claims)
```

## Changes

### Gleam Layer

#### DELETE: `levee_auth/src/jwt.gleam`

This 198-line file manually implements base64url encoding, HMAC-SHA256 signing,
constant-time signature comparison, and payload decoding. All replaced by gwt.

#### REWRITE internals: `levee_auth/src/token.gleam`

Public API preserved (`TokenClaims`, `TokenConfig`, `TokenError`, `create`,
`verify`, helper functions). Internal changes:

- **`create()`** — switch from building `json.Json` + `jwt.sign()` to gwt builder:
  ```gleam
  gwt.new()
  |> gwt.set_subject(claims.user_id)
  |> gwt.set_issuer("levee")
  |> gwt.set_issued_at(claims.iat)
  |> gwt.set_expiration(claims.exp)
  |> gwt.set_payload_claim("tenant_id", json.string(claims.tenant_id))
  |> gwt.set_payload_claim("document_id", json.string(claims.document_id))
  |> gwt.set_payload_claim("scopes", json.string(scopes_str))
  |> gwt.to_signed_string(gwt.HS256, secret: config.secret)
  ```

- **`verify()`** — switch from `jwt.verify()` + manual extraction to:
  ```gleam
  gwt.from_signed_string(token, secret: secret)
  // then gwt.get_subject(), gwt.get_payload_claim(), etc.
  ```

- Error mapping: `gwt.JwtDecodeError` variants → existing `TokenError` variants.

#### UPDATE: `levee_auth/gleam.toml`

- Add: `gwt >= 2.0.0 and < 3.0.0`
- Remove: `gleam_crypto` (only used by jwt.gleam for HMAC)

#### NO CHANGES: `levee_protocol/`

`TokenClaims` in `levee_protocol/types.gleam` and validation in
`levee_protocol/jwt.gleam` operate on already-decoded claims, not raw JWT strings.

### Elixir Layer

#### SIMPLIFY: `lib/levee/auth/jwt.ex`

- **`sign/2`** — delegate to `GleamBridge.create_document_token()` instead of JOSE.
  Convert Elixir claims map → Gleam function arguments.
- **`verify/2`** — delegate to `GleamBridge.verify_token()` instead of JOSE.
  Convert Gleam claims → Elixir claims map format.
- **Test helpers** — stay, updated to call new `sign/2`.
- **Scope utilities** — stay as-is (pure map operations).
- **`atomize_claims`** — still needed for format conversion.

#### MINOR UPDATE: `lib/levee/auth/gleam_bridge.ex`

Token functions section already wraps Gleam token module. May need small adjustment
to ensure `verify_token/2` returns claims convertible to the existing
`token_claims()` shape (Gleam uses `user_id`, Elixir expects `user: %{id: ...}`).

#### NO CHANGES: `lib/levee_web/plugs/auth.ex`

Calls `JWT.verify/2` and `Bridge.validate_claims_*` — both interfaces unchanged.

#### NO CHANGES: `lib/levee/protocol/bridge.ex`

`elixir_claims_to_gleam` and `validate_claims_*` operate on Elixir claims map.

#### UPDATE: `mix.exs`

Remove `{:jose, "~> 1.11"}`.

### Key Constraint

The Elixir claims map shape must be preserved:
```elixir
%{
  documentId: String.t(),
  scopes: [String.t()],
  tenantId: String.t(),
  user: %{id: String.t()},
  iat: integer(),
  exp: integer(),
  ver: String.t(),
  jti: String.t() | nil
}
```

The auth plug, protocol bridge, and channel code all depend on this format.

## Wire Format Compatibility

Tokens signed by the old code will verify with gwt and vice versa — both use
standard HS256 HMAC-SHA256 with identical base64url encoding. Custom claim names
(`tenant_id`, `document_id`, `scopes` as comma-separated string) are preserved.

## Two TokenClaims Types

- `levee_auth/token.gleam:TokenClaims` — token creation/verification, typed `Scope` list
- `levee_protocol/types.gleam:TokenClaims` — validation, `List(String)` scopes

Independent types, both unchanged.

## Testing Plan

1. `just build-gleam`
2. Run Gleam tests for levee_auth
3. `cd server && mix compile --force`
4. `cd server && mix test` — all existing tests pass unchanged
5. Verify round-trip: create → verify → validate claims

## Risks

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| gwt base64url padding differs from hand-rolled | Low | Existing test suite covers this |
| gwt handles exp/iat as floats vs ints | Low | gwt docs confirm int types |

## Files Changed

| File | Action |
|------|--------|
| `server/levee_auth/src/jwt.gleam` | Delete |
| `server/levee_auth/src/token.gleam` | Rewrite internals |
| `server/levee_auth/gleam.toml` | Update deps |
| `server/lib/levee/auth/jwt.ex` | Simplify to bridge delegation |
| `server/lib/levee/auth/gleam_bridge.ex` | Minor update |
| `server/mix.exs` | Remove jose dep |
