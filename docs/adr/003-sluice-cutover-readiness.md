# ADR-003: Sluice runtime cutover readiness gate

- **Status:** Accepted
- **Date:** 2026-06-30
- **Context:** Closing out the Sluice-first migration plan without
  prematurely retiring Phoenix

## Context

ADR-002 established the destination architecture: Sluice (the standalone
`server/sluice/` Gleam service) becomes the primary runtime once it passes
the Routerlicious compatibility suite (`sluice-routerlicious.test.ts`) for
both the `sluice-direct` and `levee-proxy` targets across create, load,
sync, reconnect, summaries, and signals. Recent work has progressively
thinned Phoenix's Socket.IO shim (`socket_io_plug.ex`,
`socket_io_websock.ex`) down to a transport/session shell that delegates
framing, `connect_document` decisions, and session/signal/nack protocol
logic to Sluice-owned modules (`Levee.Sluice`, `sluice/socketio`,
`sluice/connect_document`, etc.).

That is real, incremental progress toward the cutover — but it is not the
cutover itself. As of this ADR:

- `sluice-routerlicious.test.ts` has 28 outstanding `it.todo(...)` gaps
  (see the file's header comment and `cutover-readiness.json`), covering
  connect/create parity gaps for `sluice-direct`, op sequencing/fan-out/nack
  behavior, signal fan-out, cross-client sync convergence, summary
  ack/nack, reconnection/delta-catch-up, REST route parity (session
  discovery, git refs, deltas catch-up shape), and auth/storage-backend
  behavior coverage.
- Phoenix/Levee still owns controllers, the JWT auth plug, the
  Session/Registry storage runtime, the admin UI, and legacy Phoenix
  Channels support (`/socket`) alongside the Socket.IO shim.
- No production traffic has been re-pointed at standalone Sluice; Levee's
  proxy target is still the only integration-tested path with full REST
  coverage.

Without an explicit, checked gate, it would be easy for a future change to
declare victory based on partial progress (e.g., "the shim is thin now, so
we're basically done") and start removing Phoenix surfaces while real gaps
remain. This ADR defines that gate as a repo-tracked, executable artifact
rather than prose alone.

## Decision

1. **`client/packages/levee-driver/test/integration/cutover-readiness.json`**
   is the single source of truth for cutover readiness. It records:
   - the required conformance categories (create/load/sync/reconnect/
     summaries/signals) and required targets (`sluice-direct`,
     `levee-proxy`) from ADR-002,
   - the Phoenix-owned surfaces that must be ported, replaced, or
     explicitly re-scoped before removal (admin UI, controllers, auth
     plug, Session/Registry runtime, the Socket.IO shim itself),
   - the expected outstanding `it.todo` count in
     `sluice-routerlicious.test.ts`, and
   - an explicit `readyForCutover` boolean that a human must flip.

2. **`cutover-readiness.ts`/`cutover-readiness.test.ts`** make the gate
   executable and run in the default (non-network-gated) test suite:
   - `countOutstandingConformanceTodos()` scans
     `sluice-routerlicious.test.ts` for `it.todo(...)` calls and returns a
     live count.
   - The test suite fails if that live count drifts from
     `expectedOutstandingTodoCount` in the manifest, forcing anyone who
     changes conformance coverage to also touch the gate in the same
     change (instead of silently improving or regressing conformance
     without acknowledgment).
   - The test suite asserts `ready === false` today, and would fail if
     `readyForCutover: true` were set while outstanding gaps remain —
     guarding against an inconsistent manual edit.

3. **Runtime removal (Phoenix Channels, the Socket.IO shim, Phoenix
   controllers/auth/admin as permanent scaffolding) may only proceed
   after**:
   - `expectedOutstandingTodoCount` reaches `0` (all conformance gaps
     closed for both targets), AND
   - every entry in `phoenixOwnedSurfacesPendingRetirement` has been
     ported to Sluice, replaced, or removed from the list with a
     documented reason, AND
   - `readyForCutover` is deliberately flipped to `true` in the same
     change that begins the removal work, with this ADR (or a successor)
     updated to record the decision and date.

4. **`socket_io_plug.ex` and `socket_io_websock.ex` document their removal
   gate inline**, pointing back at this ADR and the manifest, so anyone
   reading the shim code sees the same constraint as anyone reading the
   test suite.

## Consequences

- The project has a durable, hard-to-fake mechanism (a failing test, not
  just a stale doc) that prevents claiming migration completion before
  `sluice-routerlicious.test.ts` conformance and Phoenix surface parity are
  both actually met.
- Any PR that closes conformance gaps must update
  `cutover-readiness.json`'s `expectedOutstandingTodoCount` (and, for the
  final gap, `readyForCutover`) or its tests fail — making the manifest
  self-maintaining rather than a document that quietly rots.
- `just check-cutover-readiness` gives a one-line command to check current
  status without reading test output line-by-line.
- This ADR does not perform any runtime removal. It only records the gate
  and the trigger condition, matching ADR-002's approach.

## Alternatives considered

### Prose-only checklist in a markdown doc

Rejected: nothing would fail the build if the checklist quietly went stale
relative to the actual `it.todo` count, and nothing would stop someone from
editing "readyForCutover: true"-equivalent prose without closing the gaps.

### Gate on CI/deploy config instead of a test

Rejected for now: the project doesn't have a deploy pipeline that reads
per-service readiness flags, and a test is easier to run locally
(`just check-cutover-readiness` / `pnpm test`) and keeps the gate colocated
with the conformance suite it measures.
