# ADR-002: Client compatibility strategy for the Floodgate migration

- **Status:** Accepted
- **Date:** 2026-06-30
- **Context:** Floodgate-first migration — client package (`levee-driver`/`levee-client`) direction

## Context

The server-side migration is moving runtime ownership from Phoenix/Levee to
the standalone Gleam `floodgate/` service, which speaks the same Socket.IO/REST
protocol as upstream Routerlicious (see
`client/packages/levee-driver/test/integration/floodgate-contract.ts`, the
executable contract, and `floodgate-routerlicious.test.ts`, the compatibility
suite that exercises an *unmodified* `@fluidframework/routerlicious-driver`
against Floodgate). That work established the server-side principle: **Floodgate is
the destination service; Phoenix/Levee is temporary migration scaffolding.**

This ADR extends that decision to the TypeScript client packages, which until
now had no documented long-term direction:

- `@tylerbu/levee-driver` — a custom Fluid driver built against Phoenix
  Channels, used because early Levee had no Socket.IO-compatible endpoint.
- `@tylerbu/levee-client` — a high-level `fluid-static`-style wrapper around
  `levee-driver`.
- `@tylerbu/levee-example`, `@tylerbu/levee-presence-tracker` — example apps
  built on the driver/client.

Once Floodgate implements the Routerlicious wire protocol directly, an
unmodified `@fluidframework/routerlicious-driver` can talk to it. Continuing
to invest in a bespoke Phoenix Channels driver stops making sense once that
parity is reached — it becomes a second protocol implementation to maintain
with no unique capability advantage.

## Decision

1. **Official Routerlicious-compatible clients become the primary long-term
   path.** Once Floodgate passes the create/load/sync/reconnect/summaries/signals
   conformance surface in `floodgate-routerlicious.test.ts` for a given target,
   consumers should use `@fluidframework/routerlicious-driver` (or
   `@fluidframework/routerlicious-urlResolver` /
   `@fluidframework/azure-client`-style wrappers) pointed at Floodgate, not
   `@tylerbu/levee-driver`.

2. **`@tylerbu/levee-client` becomes a thin convenience layer over the
   official Routerlicious path, not a permanent Phoenix-specific wrapper.**
   New high-level ergonomics (container creation helpers, audience utilities)
   should be designed so they can be re-pointed at a Routerlicious-backed
   service factory without a breaking API change for consumers. No new
   Phoenix Channels-only protocol features should be added to
   `levee-client`.

3. **`@tylerbu/levee-driver`'s Phoenix Channels transport is legacy during the
   migration and becomes deprecated once Floodgate conformance is reached.**
   Concretely: deprecate `levee-driver`'s Phoenix Channels code paths
   (`leveeDeltaConnection.ts`, `socket_io_websock.ex` proxying) once
   `floodgate-routerlicious.test.ts` passes for both `floodgate-direct` and
   `levee-proxy` targets across connect, ops, reconnection, signals, and
   summaries. Until then it remains supported as the working driver for
   Phoenix-only deployments.

4. **No new investment in the Phoenix Channels protocol.** Bug fixes and
   test/reliability work on `levee-driver` continue as needed to keep current
   consumers (`levee-example`, `levee-presence-tracker`, existing app users)
   working, but new realtime features (e.g. new op types, new signal
   semantics) should be implemented against the Floodgate/Routerlicious contract
   first, not the Phoenix Channels driver.

5. **`floodgate-routerlicious.test.ts` is the acceptance suite of record** for
   deciding when the above transition is safe. The `test:floodgate-routerlicious`
   pnpm script and `just test-floodgate-routerlicious` recipe are the primary,
   north-star conformance check going forward; the existing
   `test:integration` (Phoenix/Docker) suite remains the legacy regression
   check for the current Phoenix-backed driver during the transition.

## Consequences

- Examples (`levee-example`, `levee-presence-tracker`) should migrate to the
  official Routerlicious/Floodgate path once conformance holds, rather than
  gaining new Phoenix-only features.
- `levee-driver`'s `CLAUDE.md`/package docs are updated to point at this ADR
  so contributors don't add new Phoenix Channels protocol surface by default.
- No packages are renamed, removed, or marked deprecated in `package.json`
  yet — this ADR records the *decision and trigger condition* rather than
  the deprecation itself, since `floodgate-routerlicious.test.ts` conformance
  is not yet complete for all scenarios (see `it.todo`/live-gated cases in
  that file).
- Future tasks that reach full conformance should: (a) add a `deprecated`
  note to `levee-driver`'s `package.json`/README, (b) update
  `levee-example`/`levee-presence-tracker` to use the Routerlicious driver,
  and (c) revisit whether `levee-client` should re-export a
  Routerlicious-backed factory directly instead of wrapping `levee-driver`.

## Alternatives considered

### Keep `levee-driver` as the permanent, primary client

Rejected: it duplicates protocol logic that Floodgate now implements natively
against upstream Fluid tooling, doubles the maintenance surface, and forfeits
compatibility with the broader Fluid Framework/Routerlicious ecosystem
(tooling, newer driver versions, non-Levee Routerlicious-compatible
backends).

### Deprecate `levee-driver` immediately

Rejected: `floodgate-routerlicious.test.ts` still has live-gated and
`it.todo` gaps (see file header) for standalone Floodgate vs. the Levee proxy
target. Deprecating before conformance is reached would break current
Phoenix-only consumers with no working replacement.
