# ADR-006: Extract `silt` — a shared git-object + Historian library

- **Status:** Proposed
- **Date:** 2026-07-14
- **Related:** [ADR-004](004-coexisting-client-stacks.md) (shared protocol/domain
  libraries are encouraged; server stacks stay decoupled),
  [ADR-005](005-floodgate-storage-backend.md) (storage *backends* stay separate).
  Follows the `levee_protocol → spillway` convergence precedent.

## Context

Both server stacks implement a git-like, content-addressed object store
(blobs / trees / commits / refs) and the Routerlicious "Historian" REST surface
that exposes those objects as document summaries/snapshots. That logic is
duplicated — and has already **drifted into two incompatible schemes**:

| | Floodgate | Levee |
|---|---|---|
| Hash | **SHA-1**, git-canonical framing (`"blob " <len> \0 <content>`) → real git object IDs (`floodgate/git.gleam` `blob_sha`/`sha1`) | **SHA-256** of JSON serialization (`levee_storage/ets.gleam` + `pg.gleam` `compute_sha256`) |
| Object serialization | git-canonical | ad-hoc JSON |
| Historian responses | `object_response`, `commit_history_response`, `ref_response`, `decode_ref` (Gleam) | `format_tree_response`, `blob_url`, … (Elixir `git_controller.ex`) |

Consequences of the drift:

- The two stacks produce **different object IDs for identical content**, so git
  objects are not portable across stacks and only Floodgate's IDs are
  git/Routerlicious-compatible (what the official Fluid driver requires).
- SHA computation exists in **three** implementations (`floodgate/git.gleam`,
  `levee_storage/ets.gleam`, `levee_storage/pg.gleam`), and Historian response
  shapes in two — every change risks further divergence and conformance breaks.

The git object *model* is pure logic over content (SHA + serialization), so it
can be shared **without** coupling the storage backends that ADR-005 keeps
separate. This is the same move as `spillway`: extract the shared domain logic,
let each stack keep its own runtime/storage.

## Decision

Extract a new shared Gleam library, **`silt`**, that both stacks depend on. It
contains two conceptual layers in one package:

1. **Git object model** — content-addressed blob/tree/commit/ref with
   **git-canonical SHA-1 framing** (Floodgate's scheme, since it is the
   git/Routerlicious-compatible one) and canonical object serialization.
2. **Historian response shapes** — the Routerlicious-compatible JSON/URL
   response builders (`object_response`, `commit_history_response`,
   `ref_response`, `decode_ref`).

`silt` is **pure logic over content and values** — it does **not** own
persistence. Given content it returns a SHA + serialized object; given objects
it returns Historian JSON. Each stack keeps its own store (Floodgate's
`shelf_store`, Levee's `levee_storage`), per ADR-005, and calls `silt` for
hashing, serialization, and response shaping.

Consumption:
- `floodgate/git.gleam` becomes a thin adapter over `silt` + its `store.Backend`.
- `levee_storage` and `levee_web/git_controller.ex` call `silt` (via the Gleam
  bridge, as they already call `spillway`/`floodgate`) for SHA, serialization,
  and response shapes — **replacing Levee's SHA-256/JSON scheme with the
  git-canonical one**.

### Name

Water/hydrology theme, matching `levee`, `floodgate`, `spillway`, `dewdrop`:
**silt** is sediment that settles and layers over time — an apt metaphor for
immutable, content-addressed objects accumulating into history.

## Why this is acceptable

- **Kills the SHA-drift bug class.** One content-addressing implementation ⇒
  identical, git-compatible object IDs across both stacks ⇒ objects are portable
  and Levee's Historian becomes git/Routerlicious-conformant.
- **Single source for Historian response shapes** ⇒ conformance parity.
- **Respects ADR-005.** `silt` is backend-agnostic pure logic; it does not
  touch persistence, so storage backends stay independent.
- **Follows ADR-004 + the spillway precedent** for shared protocol/domain libs.

## Consequences

- **Behavior change for Levee's git endpoints:** object IDs move from SHA-256/
  JSON to git-canonical SHA-1. Any persisted Levee objects keyed by the old
  hashes would need migration or a clean cutover; worth confirming whether any
  deployment depends on the current IDs.
- **New external dependency to govern** (a git dep, like `spillway`/`beryl`).
  Pin `silt` to a commit — do not track `ref = "main"` — per the
  [dewdrop#5](https://github.com/tylerbutler/dewdrop/issues/5) lesson about
  `main` drift breaking downstream builds.
- Some response shaping currently in Elixir (`git_controller.ex`) moves into
  `silt` (Gleam) and is invoked through the bridge.

## Known risks

1. **Byte-exact serialization.** Object IDs depend on the *exact* header/
   serialization bytes. `silt` must fix one canonical framing so SHAs match
   git and are stable across stacks; any difference silently changes IDs.
2. **Elixir consumption.** Levee reaches `silt` through the Gleam bridge; the
   bridge surface grows. Mechanical, but a new interop seam to maintain.

## Alternatives considered

### Keep it duplicated (status quo)

**Rejected.** The duplication has already drifted into incompatible hashes; the
cost is paid now (non-portable objects, non-conformant Levee IDs), not just as a
future risk.

### Two libraries — a generic git-object lib + a Historian veneer

The git object model is generic (reusable beyond Fluid); the Historian shapes
are Fluid-specific. **Deferred**, not rejected: ship one package now to solve
the duplication with minimal governance; split later (a generically-named
git-object lower layer, with `silt` as the Historian layer on top) only if the
object model warrants standalone reuse.

### Fold into `spillway`

**Rejected.** `spillway` is protocol logic (sequencing, sessions, signals, JWT).
Content-addressed storage + Historian is a distinct domain and warrants its own
package.

### Share `levee_storage` / a storage library

**Rejected.** ADR-005 keeps storage *backends* separate. `silt` is the
backend-agnostic object/response *logic*, not the store.

## Follow-ups

- Implement: create `tylerbutler/silt`; move SHA + object model + Historian
  shapes; standardize on git-canonical SHA-1; repoint `floodgate/git.gleam`,
  `levee_storage`, and `git_controller.ex`; pin to a commit.
- Decide migration vs clean cutover for existing Levee object IDs.
- Sibling unification efforts: JWT verify/parse/mint → `spillway` (Tier 1); a
  single shared Fluid-conformance fixture set (Tier 3).
