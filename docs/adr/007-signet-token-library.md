# ADR-007: Extract `signet` — a shared Fluid token/JWT package

- **Status:** Proposed
- **Date:** 2026-07-14
- **Related:** [ADR-004](004-coexisting-client-stacks.md) (shared protocol/domain
  libraries; decoupled stacks), the `levee_protocol → spillway` convergence,
  [ADR-006](006-silt-git-historian-library.md) (sibling extraction),
  spillway PR [#2](https://github.com/tylerbutler/spillway/pull/2) (interim step).

## Context

The Fluid document-token (HS256 JWT) logic is implemented **three times** in
Gleam — all producing the same token shape (`TokenClaims` with
`documentId`/`tenantId`/`scopes`/`ver "1.0"`, scopes `doc:read`/`doc:write`/
`summary:write`):

1. `spillway/jwt` — claim validation, plus HS256 crypto as of PR #2
2. `floodgate/auth.gleam` — Floodgate's verify/extract/mint
3. `levee_auth/token.gleam` + `jwt.gleam` — Levee's `create_document_token`/
   `verify`

(There is also an Elixir jose path in `jwt.ex`.)

Spillway PR #2 (Tier-1 unification) dedupes **floodgate ↔ spillway** by moving
the crypto into `spillway/jwt`. But converging the **third** consumer exposes a
structural problem: `levee_auth` is a **general auth library** (password
hashing, users, sessions) that merely *mints Fluid tokens*. Making it depend on
all of `spillway` — sequencing, sessions, signals, nack, schema — just to share
JWT is the wrong dependency shape. A non-protocol consumer needing the shared
token logic is the signal that the token domain wants to be its **own focused
package**, not a module inside the protocol library.

## Decision

Extract a focused Gleam package, **`signet`** (a signet is a seal used to *sign
and authenticate* documents — apt for a signed credential), owning the Fluid
token domain:

- **Types:** `TokenClaims`, `Scope` (migrated from `spillway/types`).
- **Crypto:** HS256 `verify_signature`, `extract_token` (Basic/Bearer),
  `mint_token`, `JwtCryptoError` (from spillway PR #2 / `floodgate/auth.gleam`),
  via `gleam_crypto` — no FFI.
- **Validation:** `validate_expiration`/`tenant`/`document`/`scope`,
  `validate_connection`/`read`/`write`/`summary_access`, `has_scope`,
  `error_to_http_code` (from `spillway/jwt`).

Consumers depend on `signet`:

- **`spillway`** depends on `signet` and re-exports `TokenClaims` for its
  protocol modules (which use it in the connect/sequencing path).
- **`floodgate/auth.gleam`** → thin wrapper over `signet`.
- **`levee_auth/token.gleam`** → thin wrapper over `signet` — a **light**
  dependency that does not pull in the Fluid protocol surface.

`signet` is pure Gleam (`gleam_stdlib`, `gleam_json`, `gleam_crypto`), no FFI.

### Name

`sluice` (the water-themed candidate) is already taken by another component.
`signet` deliberately steps off the water motif — like `cairn` was considered
for [ADR-006] — because the sharpest metaphor here is a **signed credential**,
not flow control.

## Why this is acceptable

- **Retires three JWT implementations into one** ⇒ no drift in token format or
  verification across the stacks.
- **Correct dependency shape:** `levee_auth` shares the JWT logic without
  inheriting `spillway`'s protocol modules.
- **Respects ADR-004** (shared domain library) and stack decoupling — `signet`
  is pure token logic, coupling no runtime or transport.

## Consequences

- **`TokenClaims`/`Scope` migrate out of `spillway/types` into `signet`.**
  `spillway` depends on `signet` and re-exports them. Invasive (the types are
  used across spillway) but mechanical.
- **Another git dependency to govern.** Pin `signet` to a commit — not
  `ref = "main"` — per the [dewdrop#5](https://github.com/tylerbutler/dewdrop/issues/5)
  lesson about `main` drift.
- Elixir `jwt.ex` (jose) can later verify via `signet` through the bridge;
  Levee's tenant-secret rotation (`tenant_secrets.ex`) stays Elixir-side.

## Relationship to spillway PR #2

PR #2 (JWT crypto in `spillway/jwt`) is the **interim** step that already
dedupes floodgate ↔ spillway. This ADR **supersedes that placement only if
`levee_auth` is to be converged**: the crypto + validation + types then move
from `spillway` into `signet`, and `spillway` depends on `signet`. If
`levee_auth` is left with its own tokens, PR #2's in-spillway placement stands
and this ADR is not adopted. **Adopt `signet` only as part of a deliberate
"converge `levee_auth` too" effort.**

## Alternatives considered

### Keep JWT in `spillway/jwt` (PR #2 as-is)

Simplest, and already dedupes two of three. **Rejected only if** you want to
converge `levee_auth`, since that would force it to depend on all of `spillway`
or leave a third copy. Perfectly fine if `levee_auth`'s tokens stay separate.

### A generic (non-Fluid) JWT package

**Rejected.** The token shape (`TokenClaims`, Fluid scopes, `ver "1.0"`) and the
validation rules are Fluid-specific; a generic JWT library wouldn't capture the
shared claim validation. A generic HS256 layer could be slotted *under* `signet`
later if RS256/JWKS are ever needed.

### Fold `levee_auth`'s tokens into `levee_auth` only (no sharing)

**Rejected.** Leaves duplication and drift risk across three implementations.

## Follow-ups

- Sequence: decide to converge `levee_auth` → create `tylerbutler/signet` →
  migrate types + crypto + validation → repoint `spillway` (depend + re-export),
  `floodgate/auth.gleam`, `levee_auth/token.gleam` → pin to a commit. Redirect
  or supersede spillway PR #2 accordingly.
- Sibling unifications: `silt` (ADR-006), a shared Fluid-conformance fixture set.
