# Plan: Gleam-only SharedMap client for Levee

**Date:** 2026-07-01
**Status:** Proposed

## Goal

A Gleam library (BEAM target) providing a `SharedMap` that multiple Gleam clients
can edit concurrently through a levee server, with optimistic local reads,
convergence guaranteed by server sequencing, and reconnect safety.

**Out of scope for v1:**

- Interop with TS levee-client documents (those ride the real Fluid container
  runtime and carry double-enveloped ops, batch metadata, and container-runtime
  snapshot formats). The inner map op format is kept byte-identical to the TS
  `@fluidframework/map` ops so an interop layer later only has to add the outer
  datastore envelope.
- Summaries/snapshots — v1 documents bootstrap by full op replay
  (`requestOps` from 0); levee's session keeps the op log.
- Offline op stashing and the rollback API.
- msgpack serialization (JSON only).
- Signals/presence (cheap follow-on via `submitSignal`).

## Architecture

Three layers, mirroring the separation the TS code has (`mapKernel.ts` vs
`map.ts` vs the driver), but with a pure functional core:

```
┌─────────────────────────────────────────────┐
│  Public API: connect, map handle, subscribe │
├─────────────────────────────────────────────┤
│  Runtime actor ("delta manager")            │   OTP actor
│  handshake · CSN/RSN · inbound ordering ·   │
│  catch-up · resubmit · nack · event fan-out │
├──────────────────────┬──────────────────────┤
│  map_kernel (PURE)   │  wire (PURE)         │
│  sequenced + pending │  levee channel       │
│  LWW merge, acks     │  payload codecs      │
├──────────────────────┴──────────────────────┤
│  aquamarine (channel client, roost codec)   │
└─────────────────────────────────────────────┘
```

- **`map_kernel`** — pure port of the semantics in FluidFramework's
  `packages/dds/map/src/mapKernel.ts`. No process, no side effects; every
  operation returns `#(State, List(Event), List(OutboundOp))`.
- **`runtime`** — one actor per document connection. Owns the aquamarine
  channel, the kernel state, and subscriber subjects.
- **`wire`** — encoders/decoders for levee's document-channel payloads,
  reusing `spillway/types` and `spillway/message` (`ConnectMessage`,
  `ConnectedMessage`, `SequencedDocumentMessage`) so client and server can't
  drift. If those types need adjustments for client use, upstream them to
  spillway rather than duplicating.

New repo following the water theme, `target = "erlang"`, startest + qcheck to
match spillway/beryl conventions.

## Wire contract (confirmed against `server/lib/levee_web/channels/document_channel.ex`)

| Direction | Event                      | Payload                                                                                       |
| --------- | -------------------------- | --------------------------------------------------------------------------------------------- |
| join      | Phoenix topic `document:{tenant}/{doc}` | —                                                                                 |
| →         | `connect_document`         | `ConnectMessage` (mode: write)                                                                 |
| ←         | `connect_document_success` | `ConnectedMessage`: `client_id`, `checkpoint_sequence_number`, `initial_clients`, service config |
| →         | `submitOp`                 | `{clientId, messageBatches: [[DocumentMessage]]}`                                              |
| ←         | `op`                       | `{clientId, op: [SequencedDocumentMessage]}`                                                   |
| →         | `requestOps`               | `{from: sn}` — in-band delta catch-up                                                          |
| →         | `noop`                     | `{clientId, referenceSequenceNumber}` — MSN heartbeat                                          |
| ←         | `nack`                     | `{clientId, nacks}`                                                                            |

**Document format (the Gleam-only simplification):**
`DocumentMessage.contents = {address: channel_id, contents: map_op}` — one
envelope level, where `map_op` is byte-identical to the TS format:

```json
{ "type": "set", "key": "k", "value": { "type": "Plain", "value": ... } }
{ "type": "delete", "key": "k" }
{ "type": "clear" }
```

Levee sequences contents opaquely, so nothing server-side changes.

## Kernel design

State and transitions, translated from `mapKernel.ts`:

```gleam
pub type MapState {
  MapState(
    sequenced: Dict(String, Json),
    insertion_order: List(String),        // JS-Map-like iteration order
    pending: List(PendingEntry),          // ordered, oldest first
  )
}

pub type PendingEntry {
  PendingLifetime(key: String, sets: List(Json))  // consecutive sets to a key
  PendingDelete(key: String)
  PendingClear
}

pub fn set(state, key, value)    -> #(MapState, List(Event), MapOp)
pub fn delete(state, key)        -> #(MapState, List(Event), MapOp)
pub fn clear(state)              -> #(MapState, List(Event), MapOp)
pub fn get(state, key)           -> Option(Json)   // optimistic overlay read
pub fn apply_remote(state, op)   -> #(MapState, List(Event))
pub fn ack_local(state, op)      -> MapState       // commit pending → sequenced
pub fn entries(state)            -> List(#(String, Json))
```

Decisions baked in:

- **Values are `gleam/json.Json`** for v1 (serializable, structurally
  comparable in tests). A typed generic wrapper can layer on later.
- **Ack matching by FIFO, not identity.** The TS kernel matches acks to pending
  entries by JS reference identity (`pendingEntry === localOpMetadata`) because
  the Fluid runtime round-trips an object reference. An inbound sequenced
  message is "ours" iff its `client_id` matches our connection's; then pop the
  corresponding head pending entry (per-key FIFO for sets within a lifetime,
  matching the TS `shift()` + identity-assert behavior). Assert-fail loudly on
  mismatch, same as the TS asserts.
- **Event suppression rules** ported exactly: remote changes masked by local
  pending ops emit nothing; local clear emits `Cleared` plus per-key
  `ValueChanged` events.
- **Insertion-order iteration** via an explicit key-order list, since Gleam
  `Dict` is unordered. Preserves the TS iterator contract: sequenced entries
  first (in insertion order), then un-acked pending lifetimes, with pending
  deletes/clears respected.

## Runtime actor

Messages in: public API calls, aquamarine inbound frames, subscriber
(un)registration. Responsibilities:

1. **Handshake** — join topic, send `connect_document`, hold ops until
   `connect_document_success`, record `client_id` and
   `checkpoint_sequence_number`, then `requestOps(from: 0)` (v1 bootstraps by
   full replay).
2. **Outbound** — stamp each op with the next CSN and current last-seen SN as
   RSN (the client half of `spillway/sequencing`'s discipline), send via
   `submitOp`, keep `#(csn, DocumentMessage)` in an in-flight queue.
3. **Inbound ordering** — track `last_seen_sn`; buffer out-of-order ops; on a
   gap, `requestOps(from: last_seen_sn)` and drop buffered duplicates by SN.
   Route each contiguous op to the kernel (`ack_local` for ours,
   `apply_remote` otherwise); ignore system message types (`join`/`leave`/
   `noop`) except for updating `last_seen_sn`.
4. **Reconnect** — on channel close: rejoin, re-handshake (new `client_id`),
   catch up via `requestOps`, then resubmit the in-flight queue in order with
   **fresh CSNs under the new client_id**, remapping the in-flight queue so
   ack-matching still works. This is the trickiest state machine in the
   project; it gets its own test suite.
5. **Heartbeat** — periodic `noop` with current RSN when idle, so the server's
   MSN advances.
6. **Nacks** — v1 policy: resubmit on retryable nacks (e.g. rate limit); crash
   the actor with a descriptive error on non-retryable (bad scope, size) —
   supervisor restarts and re-syncs. BEAM idiom, avoids silent divergence.
7. **Events** — fan out kernel events to subscriber `Subject(MapEvent)`s.

## Public API sketch

```gleam
let assert Ok(doc) = levee_map.connect(
  url: "ws://localhost:4000/socket",
  tenant: "default", document: "dice", token: jwt,
)
let map = levee_map.root(doc)                    // channel_id "root"
levee_map.set(map, "die", json.int(4))
let value = levee_map.get(map, "die")
let events = levee_map.subscribe(map)            // Subject(MapEvent)
```

## Milestones

**M1 — Kernel (3–5 days).** Pure kernel + unit tests + qcheck properties:
(a) *convergence* — any interleaving of the same sequenced op stream yields
equal state on all clients; (b) *ack transparency* — acking your own ops never
changes the optimistic view; (c) *rebase equivalence* — optimistic view ≡
sequenced state with pending ops replayed. Exit: properties pass at high
iteration counts.

**M2 — Shared test corpus (2–3 days).** A TS harness in the FluidFramework
repo drives the real `MapKernel` (via `SharedMap` + `MockContainerRuntimeFactory`)
through scripted scenarios — set-racing-clear, delete-vs-remote-set,
interleaved acks, multi-key lifetimes, iteration order — and dumps
`{scenario, steps, observations}` JSON. The Gleam test suite replays the same
files against `map_kernel` and asserts identical states, iteration order, and
events. Exit: Gleam kernel matches the TS oracle on every scenario.

> The harness lives on the `feat/map-corpus-harness` branch of the
> FluidFramework workspace checkout, under
> `packages/dds/map/src/test/mocha/corpus/`. Generated corpus JSON is copied
> into this repo (or the new client repo) as test fixtures.

**M3 — Wire + happy-path runtime (4–6 days).** Codecs against
`spillway/message` types; runtime actor doing handshake → submit → ack →
remote-apply against a live levee dev server (`just server`). Exit: two Gleam
clients converge on concurrent edits; integration test in CI.

**M4 — Resilience (4–6 days).** Gap detection + `requestOps` catch-up,
reconnect/resubmit state machine with client_id remap, nack policy, noop
heartbeat. Test by killing the channel mid-burst and asserting convergence +
no lost/duplicated ops.

**M5 — Polish + example (3–4 days).** Public API, docs, and a Gleam
dice-roller mirroring `levee-example` — ideally Lustre so the demo is Gleam
end-to-end. Exit: README quick-start works from scratch against `just server`.

Total: **~3–4 weeks**, with M1+M2 de-risking the only semantically hard part
before any networking exists.

## Open questions / risks

- **Exact join-topic and `connect_document` payload shape** — mirror what
  `leveeDeltaConnection.ts` sends (it's the reference client). Worth extracting
  into a fixture set the way `phoenix_channel_fixtures` does for beryl, so the
  Gleam client and levee test against identical frames.
- **aquamarine reply-matching caveat** — dewdrop's docs mention an open
  upstream issue around reply refs; levee is Phoenix-channels so we're on the
  roost codec path, but M3 should validate reply handling early.
- **`requestOps` bounds** — full replay from 0 is fine for v1 docs, but check
  levee's op-log retention (`session.ex` keeps ops in memory); if it truncates
  below the checkpoint, v1 needs docs created fresh or a "load from summary"
  escape hatch earlier than planned.
- **Multiple maps per document** work naturally via `address`, but v1 ships
  with just the root map to keep the API small.
