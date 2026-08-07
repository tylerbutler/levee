# Closing the Floodgate Gaps

## Implementation status — second landing (2026-08-06)

Everything in this plan is now done except what is listed as **deliberately not
done** below. Six commits, one per item, in this order:

| Commit | Item | Gate |
|---|---|---|
| `supervise the memory store backend` | 1.1 leftover | `gleam test` 129 |
| `honour the advertised Engine.IO ping timeout` | 1.2 | 130 |
| `cap the op history and evict idle documents` | 1.3 | 132 |
| `index ops and refs by topic instead of scanning` | 3.2 | 133 |
| `stop dropping dewdrop's close encoder` | Phase 5 close frame | 135 |
| `honour signal targeting` | 3.1 | 137 |

`gleam test` 128 → 137. Dual-mode conformance **38 + 7** and drop-in parity
**53 passed / 1 failed** (the intentional 401) at every step — including 3.1,
which this plan expected to move a count. It did not: neither suite covers signal
targeting, so the new three-client tests are what pin it.

### Four findings that changed the work

1. **`Doc.history` was not dead.** A grep for readers finds only writes, but it is
   passed positionally as `Connected`'s `initial_ops`, which becomes
   `initialMessages`. So the fix is the plan's original one — *cap* it — not
   delete it. Capped at 1000 and stored newest-first via
   `session_logic.add_to_history`, matching levee's `@max_history_size` and
   `op_history` exactly; reversed at the two read sites. Storing it newest-first
   is also what removes the `list.append` copy per op, so reusing the spillway
   helper turned out to be both the parity move and the performance one, despite
   this plan saying it could not be reused.
2. **1.2's reaping was already working.** The coordinator sweeps *all* sockets,
   joined or not, and the `register_closer` added in the first landing lets it
   actually close them. What was missing was a test and the transport-level pong
   deadline. Making the heartbeat window configurable
   (`FLOODGATE_HEARTBEAT_TIMEOUT_MS`, defaulting to beryl's own 60 s) is what made
   the sweep testable at all.
3. **3.1 needed no client→socket map.** `join` assigns `socket.id(sock)` as the
   Fluid client id, so a recipient *is* a socket id and `beryl.send_info`
   addresses it directly. Much cheaper than this plan assumed.
4. **The ops table could not simply become a bag.** `put_op` must keep
   overwrite-by-`(topic, sn)` to stay observationally identical to
   `memory_store`'s dict, and a bag dedupes only exact duplicates. The set stays
   the authority with a bag as the *index*. This also surfaced an upgrade hazard
   the plan missed: a DETS directory written before the indexes existed has no
   index files, so without a backfill on open every pre-existing document would
   read back as having no history.

### Deliberately not done

- **Op pruning below the last summary** (1.3's third axis). `requestOps` and
  `GET /deltas` can still request those ops, so pruning changes observable API
  results. Rather than ship a default-off path nobody exercises, this stays a
  known unbounded axis: stored ops grow without limit even though in-memory
  history and the document cache no longer do.
- **Telemetry and a metrics endpoint** (Phase 5). `beryl/telemetry.gleam` and
  `beryl/stats.gleam` remain unwired; there is still no visibility into connection
  counts or op rates. `session.cached_documents` was added along the way and is
  the kind of thing such an endpoint would expose.
- **Per-document sequencing** (3.3) and **the ADR-009 extraction blocker**, both
  already deferred by this plan.
- **The `message_too_large` nack** — see the first landing's note below; the
  reasoning is unchanged.

### Also still open

- **Cross-table atomicity.** A `submitSummary` is still five independent DETS
  inserts with no transaction; a crash mid-sequence leaves inconsistent state.
  Rehydration tolerates a missing summary, so this is a known limitation rather
  than a live fault.
- **shelf table ownership.** `shelf_store`'s ETS tables are owned by whichever
  process calls `new` — `main`, via `floodgate.serve` — and the `Backend` closures
  capture the table handles, so a restart of that process would leave them stale.
  `store.Backend` now has a `supervise` hook (used by `memory_store`), but fixing
  this needs the *handles* to become late-bound, not just the owner. Recorded in
  `shelf_store.new`.

## Implementation status — first landing (2026-08-06)

**Landed:** Phase 1.1 (supervise the session actor), Phase 2 (the message-size contract),
Phase 4.1 (Socket.IO origin check), Phase 4.2 (connection and rate limits), and —
opportunistically, because it lives in the same file — the `register_closer` half of
Phase 1.2.

Gates after the change: `gleam test` 128 passed (up from 108: +19 origin unit tests, +1
supervision test); dual-mode conformance **38 + 7**, unchanged; drop-in parity **53 passed
/ 1 failed**, the one failure being the intentional 401-not-403 divergence. No count moved.

**Three findings during implementation corrected this plan.** Two of them mean the original
diagnosis was wrong, so they are recorded here rather than quietly fixed:

1. **Heartbeat eviction was never disabled.** `beryl.gleam:239-240` defaults
   `heartbeat_interval_ms: 30_000` / `heartbeat_timeout_ms: 60_000`, and `beryl.gleam:650`
   derives `check_interval = timeout / 2 = 30_000`, so `coordinator.gleam:667`'s `> 0` guard
   passes and the sweep runs. The `heartbeat_check_interval_ms: 0` cited below is the
   default for a *directly constructed* coordinator config, not what `beryl_supervisor`
   passes.
2. **The real 1.2 gap was a missing closer, not a missing sweep.** floodgate never called
   `transport.register_closer`, whose own doc says it exists "so the coordinator can
   actively evict [a socket] … instead of leaving a zombie socket whose frames are silently
   dropped." Eviction therefore dropped coordinator state but could not close the underlying
   connection: the mist process stayed alive pinging into the void, and its stale RSN kept
   pinning the document's MSN. `beryl_mist.gleam:613` registers a closer; floodgate's
   hand-rolled Socket.IO transport did not. **Fixed.**
3. **Frame caps are enforced per transport, not by the coordinator.**
   `beryl.max_inbound_frame_bytes` is only a getter — beryl_mist enforces it itself at
   `beryl_mist.gleam:645,662`. So floodgate's Socket.IO endpoint, the primary Fluid path,
   had **no inbound size limit at all**, which is worse than the "advertised 16 MiB,
   enforced 1 MiB" mismatch described below. Setting the config alone would have fixed only
   the Phoenix path.

The through-line: these are all one class of bug. beryl_mist applies a guard; floodgate's
separately written Socket.IO transport does not. Origin policy, connection limiter, message
rate limiter, frame cap, and closer were *all* in that state. **Any future guard added to
beryl_mist should be checked against `floodgate/socketio_transport.gleam`.**

### What was built

- `floodgate/origin.gleam` (new) — the one origin policy both endpoints derive from, with
  pure `from_env` / `allowed` / `same_origin` so the semantics are unit-testable without a
  server. 19 tests.
- `floodgate/socketio_transport.gleam` — origin check (403) and connection-slot acquire
  (429) before upgrade; `bind_connection_slot` in `on_init` so the limiter's monitor
  reclaims the slot on abnormal death; `release_connection_slot` in `on_close`;
  `register_closer`; per-socket message rate limiting; per-frame size enforcement mirroring
  beryl_mist's `frame_too_large`.
- `floodgate.gleam` — one `FLOODGATE_MAX_FRAME_BYTES` knob (default 16 MiB) feeding the
  enforced cap, and new `FLOODGATE_MAX_CONNECTIONS_PER_IP` (256),
  `FLOODGATE_MAX_CONNECTIONS` (4096), `FLOODGATE_MESSAGE_RATE`/`_BURST` (1000/2000),
  `FLOODGATE_JOIN_RATE`/`_BURST` (100/200). All read `0` as "unlimited", per beryl.
- `floodgate/session.gleam` — `Session` now carries the actor's `process.Name` rather than
  its `Subject`, plus `new_name` / `from_name` / `start_named` / `child_spec` / `owner`.
  `start`/`start_with_backend` are retained, documented as unsupervised test helpers.
- `document_channel.gleam` — IConnected's `maxMessageSize` now reads
  `beryl.max_inbound_frame_bytes(channels)` instead of a hardcoded 16 MiB, so what is
  advertised is what is enforced.

### Deliberate deviation from this plan

Phase 2 said wiring the `message_too_large` nack was "not optional". It was **not wired**,
and the reason is that the design changed under it: with the frame cap enforced at the
transport, an oversize frame is rejected before any op is parsed, so there is no reliable
client or topic context to address a nack to — and a single op can never exceed the frame
that carried it, making a per-op check unreachable while also costing an extra full
serialization per op on the hot path. Both endpoints now close the socket instead, which is
what beryl_mist already did and what the WebSocket protocol provides for. If the frame cap
is ever raised above `maxMessageSize` to give batching headroom, the per-op check becomes
reachable and worth adding then.

## Context

Planning the .NET reimplementation of Floodgate required mapping the Gleam server in
detail, and that surfaced a set of gaps in the Gleam implementation itself — availability
holes, an incorrect advertised protocol limit, unbounded resource growth, and a batch of
beryl features that are fully implemented but never switched on.

This plan closes them. It is independent of the .NET port: every item here improves the
Gleam server on its own terms, and several also remove behaviour the port would otherwise
have to faithfully reproduce (the wrong `maxMessageSize`, the ignored signal targeting).

Scope is `server/floodgate/`. Two items touch sibling repos (`spillway`) and are called out.
The acceptance gate throughout is the existing conformance suite: `just
test-floodgate-dual-mode` (38 Routerlicious + 7 Phoenix/cross-mode) and `just
test-levee-suite-vs-floodgate` (53 of 54, the one failure being the intentional 401).
**No change here should move either count**, except where explicitly noted.

### Two corrections to the initial assessment

Both found by checking the real API surface, and both change the shape of the work:

1. **Per-socket push already exists.** `beryl.send_info` (`beryl.gleam:1026`) takes a
   `socket_id` and dispatches `coordinator.HandleInfo(socket_id, topic, handler_id, msg)` to
   that single socket's `handle_info` callback. No beryl change is needed for signal
   targeting. The actual blocker is that `floodgate.gleam:106` discards the registration
   result (`let _ = beryl.register(...)`) and builds `document_channel.new(...)` before
   `register` returns, so the channel cannot capture its own `RegisteredChannel` handle.
2. **Supervising the session actor is not a one-liner.** `session.start_with_backend`
   (`session.gleam:174-181`) does `let assert Ok(s) = actor.new(...) |> actor.start` and
   returns `Session(s.data, storage)` — a captured `Subject`. Callers hold that value; the
   registered channel captures it at construction. A supervised restart produces a *new*
   Subject, which every existing holder would miss. The session must become a **named
   process** resolved by name at call time, mirroring how beryl handles its own coordinator
   (`process.new_name` + `process.named_subject`, `beryl/supervisor.gleam:78-79`).

---

## Phase 1 — Availability

The three items that can take the service down or degrade it without bound. Do these first;
they are independent of each other and of everything below.

### 1.1 Supervise the session actor

Today `floodgate.gleam:105` calls `session.start_with_backend(storage)` *after*
`static_supervisor.start()` on line 101 — so the actor that holds sequence state for every
document lives outside the supervision tree entirely. If it dies, nothing restarts it and
every `process.call` from every channel times out after 1000 ms. Total service death, no
recovery. The `memory_store` actor (`memory_store.gleam:40`) has the same problem.

Work:

- Give the session a name (`process.new_name("floodgate_session")`) and have callers resolve
  via `process.named_subject`. `Session` becomes a name-carrying value rather than a
  Subject-carrying one, so the ~18 `process.call` sites in `session.gleam:188-371` resolve
  at call time instead of capturing.
- Convert `start_with_backend` from `let assert Ok(s) = … actor.start` to returning a
  `Result`, and expose a supervised child specification so it can be added to the existing
  `static_supervisor` alongside `beryl_supervisor.start(supervised)`.
- Ordering: the session needs the storage backend, and beryl's own tree is `RestForOne` so
  its registry precedes its coordinator. The session is independent of beryl, so
  `OneForOne` at the outer level is correct — but registration (`beryl.register`, line 106)
  must happen after both are up.
- Do the same for `memory_store`.

**Restart semantics — worth being explicit, because it is not transparent.** The session's
state is `Dict(String, Doc)`; on restart it is empty and `doc()` (`session.gleam:373-400`)
lazily rehydrates each document's `SequenceState` from persisted ops and summary. So
*sequence* state survives. But `client_states` does not, so every connected client's next
`submitOp` returns `UnknownClient` and gets nacked until it rejoins. That is still strictly
better than today's permanent death, and it matches how Levee behaves when its per-document
session restarts. Pair it with 1.2's eviction so orphaned roster entries don't persist, and
consider having the channel detect the nack and push `connect_document_error` so clients
reconnect promptly rather than retrying into a wall.

Verify: a test that kills the session actor and asserts (a) it restarts, (b) a fresh connect
on the same document resumes at the correct sequence number, (c) the conformance counts are
unchanged.

### 1.2 Reap dead connections

Two independent causes that compound:

- beryl's heartbeat eviction is off — `coordinator.gleam:183` defaults
  `heartbeat_check_interval_ms: 0`, and the guards at `:667` and `:731` mean the sweep never
  starts. So the Engine.IO and Phoenix heartbeats refresh a timer nobody reads.
- The Socket.IO ping timer (`socketio_transport.gleam:271`) fires unconditionally every 25 s
  and never times out on a missing pong.

Consequence beyond the leak: a half-open connection stays in the session roster, and **its
stale RSN pins MSN**, which blocks summarization for every other client on that document.
That makes this a correctness issue, not just hygiene.

Separately, floodgate uses **no monitors or links anywhere**. Teardown is purely
transport-driven via `socketio_transport.gleam:267` / mist's `on_close`. A connection
process that dies without `on_close` firing leaks coordinator topic membership and roster
entry permanently.

Work:

- Enable `beryl.with_heartbeat(...)` (`beryl.gleam:287`) with an interval and tolerance that
  clear a missed Phoenix heartbeat without evicting healthy-but-idle clients.
- Add a pong deadline to `socketio_transport`: track the last inbound `"3"` (or any frame),
  and close the socket when it exceeds `pingTimeout` (20 s, already advertised in the
  handshake — so this is honouring a limit we already publish).
- Add monitor-based reclaim for connection processes. `beryl/connection_limit.gleam:144,212`
  already has exactly this pattern (`process.monitor` + `select_monitors` → reclaim) to copy.

Verify: a test that drops a socket's process without a clean close and asserts the roster
and topic set are reclaimed and MSN advances.

### 1.3 Bound the growth

Three unbounded axes:

- Documents are never evicted from the session actor's `docs` dict.
- Each `Doc.history` grows without limit.
- DETS ops are never pruned below the last summary.

Work, in increasing order of care required:

- **History cap** — bound `Doc.history` and serve older ops from storage. `session_logic`
  already has `add_to_history(op, history, max_size)`; the cap just needs to be applied and
  chosen. Levee uses 1000.
- **Idle document eviction** — when a document has no connected sockets and has been idle
  past a threshold, drop it from `docs`. Safe because `doc()` rehydrates on next touch.
  Interacts with 1.1: eviction plus rehydration is the same code path a restart uses, so
  testing one tests the other.
- **Op pruning** — ops below the last accepted summary's sequence number are no longer
  needed for catch-up, since `summaryContext` bootstraps clients from the summary instead of
  replaying from SN 1. This is the one item with real risk: `requestOps` and the deltas REST
  endpoints can still ask for them, and pruning changes observable API results. Gate it
  behind an env var, default off, and land it last.

Verify: a soak test opening and closing many documents, asserting bounded memory and DETS
size. Conformance counts unchanged.

---

## Phase 2 — The message-size contract

**One decision needed before work starts.** There are currently three numbers:

| Number | Where | Value |
|---|---|---|
| Advertised to clients in IConnected | `document_channel.gleam:516,522` | 16 MB (`16 * 1024 * 1024`) |
| Advertised in the Engine.IO handshake | `socketio_transport.gleam:22-26` | 1 MB (`maxPayload: 1000000`) |
| **Actually enforced** | beryl default, never overridden | **1 MB** (`beryl.gleam:253`, `max_inbound_frame_bytes: 1_048_576`) |

So IConnected overstates the real limit by 16×. The clients that read that figure rather
than the Engine.IO handshake are the Phoenix/`levee-driver` ones, so they are the ones
affected. And a grep for `message_too_large` / `validate_message_size` across floodgate
returns **nothing** — `spillway/validation.gleam` and `spillway/nack.gleam` implement both
and neither is wired, so an oversize frame dies in the transport with no protocol-level
error explaining why.

Two coherent resolutions:

- **Raise the cap to 16 MB** — `beryl.with_max_inbound_frame_bytes(16 * 1024 * 1024)` and
  raise the Engine.IO `maxPayload` to match. Honours what we already advertise; costs a 16×
  larger worst-case inbound buffer per connection, which interacts with 4.2's connection
  limits.
- **Lower the advertisement to 1 MB** — change IConnected and leave the enforced cap alone.
  Truthful and cheap, but it is a visible protocol change for any client currently relying on
  the 16 MB figure, and Fluid summaries can be large.

Either way, **wire the nack**: call `spillway/validation.validate_message_size` in the
`submitOp` path and emit `spillway/nack.message_too_large` so oversize is a protocol error
with the exact documented message (`"Message size N exceeds limit M"`) rather than a silent
drop. That part is not optional under either choice.

Verify: a test submitting an op one byte over the limit and asserting a `message_too_large`
nack with the right code and message; plus one at exactly the limit asserting success.

---

## Phase 3 — Parity and performance

### 3.1 Honour signal targeting

`spillway/session_logic.determine_signal_recipients` is fully implemented and fully unused:
every signal broadcasts to the whole topic. Levee filters recipients, so this is a real
behavioural divergence (documented in ADR-008 as deferred).

The fix is local, per correction 2 above. `beryl.send_info` already delivers to one socket;
what's missing is the handle.

Work:

- Capture the `RegisteredChannel` that `beryl.register` returns instead of discarding it, and
  make it **late-bound** so the channel closures can read it at push time — registration has
  completed by the time any signal is pushed. A small holder (started before `register`,
  written immediately after) is enough.
- **Typing wrinkle to design around:** `RegisteredChannel(assigns, info)` is parameterized on
  the channel's assigns and info types, and it's an opaque type so floodgate cannot construct
  one itself. The holder therefore cannot live in `session.gleam` — `document_channel`
  depends on `session`, so storing it there would invert the dependency. Put the holder in a
  module that can name `document_channel`'s types, or alongside the channel itself.
- Add a `handle_info` callback to `document_channel` (it currently wires only
  `with_handle_in` and `with_terminate`) that pushes the targeted signal to the one socket.
- Switch the signal fan-out to consult `determine_signal_recipients` and use `send_info` for
  targeted signals, keeping `broadcast`/`broadcast_from` for genuine broadcasts.

**This changes observable behaviour**, so it is the one item that may move a conformance
count — in the direction of matching Levee. Note the subtlety flagged during the protocol
survey: `session_logic.determine_signal_recipients` intersects its targeted list with the
known client ids, while `signals.get_signal_recipients` does not. Pick one deliberately and
test which the clients expect.

Verify: a cross-mode test with three clients asserting a targeted signal reaches exactly one;
then re-run the Levee suite, where Levee's filtering behaviour is the reference.

### 3.2 Replace the full table scans

`shelf_store.get_ops` (`:55-65`) and `list_refs` (`:96-106`) do `set.to_list` over the entire
table and then filter — O(all ops across all documents) on every reconnect, catch-up, and
delta request. Levee has the identical bug.

DETS has no `ordered_set`, so this is not a flag change. Options, cheapest first:

- **Per-document op tables** — one shelf table per topic. Removes the scan entirely; costs
  table-handle management and a file per document.
- **An index table** — `topic → sorted [sn]`, maintained on write. Keeps one ops table; adds
  a second write per op and a consistency obligation.

The `store.Backend` closure record (`store.gleam:12-28`) is the seam, so either is
invisible above it — and `test/store_backend_test.gleam` already asserts two backends produce
identical observations, so it will catch a divergence.

Verify: the existing backend-substitution contract test, plus a benchmark showing `get_ops`
cost is independent of unrelated documents' op counts.

### 3.3 Per-document sequencing (optional, defer)

One global session actor serializes ops for *all* documents through a single mailbox with a
1000 ms call timeout, so busy documents contend for no reason. Levee is better here —
actor-per-document via Registry + DynamicSupervisor.

Per-document sequencing is **correct** today; this is throughput only. It is also the largest
change in this plan and it interacts with 1.1 and 1.3. Recommend deferring until 1.1 lands
and there is evidence of contention — at which point 1.1's named-process work makes
actor-per-document a smaller step than it is now.

---

## Phase 4 — Security

Both items are cheap because beryl already implements them; floodgate just never turns them
on.

### 4.1 Origin check on `/socket.io/`

The Phoenix path has CSWSH protection via `FLOODGATE_ALLOWED_ORIGINS`
(`floodgate.gleam:128-139`, using `beryl_mist.with_allowed_origins` /
`with_allow_all_origins`). The Socket.IO path has **no origin check at all** —
`socketio.is_socketio_websocket_request` matches path plus `Upgrade` header only. ADR-008
records the asymmetry as intentional, but it is a live CSWSH exposure for browser-based
Routerlicious clients.

Work: apply the same origin policy in `socketio_transport` before upgrade, reusing the
`FLOODGATE_ALLOWED_ORIGINS` parsing already in `phoenix_transport_config()`. Non-browser
clients send no `Origin` and must keep working — that is what makes this safe to enable.

Verify: a test asserting a cross-origin browser-style upgrade is rejected and an
`Origin`-less one is admitted. The conformance suites use non-browser clients, so counts
should not move — confirm that.

### 4.2 Rate and connection limits

`beryl/rate_limit.gleam` (87 LOC, pure token bucket) and `beryl/connection_limit.gleam`
(330 LOC, per-IP and node-wide ceilings with monitor-based reclaim) are complete and
unreferenced. Any client can open unlimited sockets and flood ops.

Work: enable `beryl.with_max_connections_per_ip` (`:320`) and `with_max_connections` (`:355`),
and wire the rate-limit buckets. Expose all three as env vars with generous defaults so the
conformance suites — which open several concurrent connections from one address — are not
tripped. Interacts with Phase 2: if the cap goes to 16 MB, the per-connection worst-case
buffer is 16× larger, so the connection ceiling matters more.

Verify: a test asserting the per-IP ceiling rejects the N+1th connection; conformance counts
unchanged.

---

## Phase 5 — Hygiene

- **Telemetry.** `beryl/telemetry.gleam` (163 LOC, typed closed-vocabulary events) and
  `beryl/stats.gleam` (122 LOC, point-in-time snapshots) are unused. There is currently no
  visibility into connection counts, op rates, or sequencer latency. Wire both and expose a
  metrics endpoint.
- **The missing `close` frame.** `server_codec.gleam` rebuilds the codec with
  `codec.new(...)`, which drops dewdrop's `encode_close`, so floodgate never emits
  `42["close"]` on graceful channel termination. Restore it by extending dewdrop's codec
  rather than rebuilding — but check first whether any client depends on the current silence.
- **Cross-table atomicity.** A `submitSummary` writes 2 ops + 1 summary + 1 object + 1 ref as
  five independent DETS inserts; a crash mid-sequence leaves inconsistent state. DETS has no
  transactions, so this needs either an idempotent replay/repair path on rehydration or a
  write-ahead marker. Lowest priority — rehydration is already tolerant of a missing summary
  — but worth recording as a known limitation if not fixed.
- **The ADR-009 extraction blocker.** Levee delegates to six floodgate Gleam modules
  (`socketio`, `connect_document`, `session_logic`, `signals`, `nack`, `rest`), and
  `application.ex` asserts they load at boot. Promoting them to `spillway` — ADR-009's
  recommended resolution — is what unblocks the standalone repo. Touches `spillway`, Levee,
  and floodgate together, so it wants its own change.

---

## Sequencing

```
Phase 1  1.1 supervise ──┐
         1.2 reap ────────┼──> independent, do in parallel
         1.3 bound  ──────┘    (1.3's eviction shares a code path with 1.1's restart)

Phase 2  size contract        needs a decision first; independent of Phase 1

Phase 3  3.1 targeting        after 1.1 (both touch registration/startup)
         3.2 scans            independent
         3.3 per-doc actors   defer

Phase 4  4.1 origin           independent
         4.2 limits           after Phase 2 (cap size affects buffer ceilings)

Phase 5  hygiene              independent; extraction blocker is its own change
```

The natural first landing is **1.1 plus the Phase 4 batch** — 1.1 removes a total-outage
failure mode, and 4.1/4.2 plus telemetry are config-level rather than development, so they
travel together cheaply. Phase 2 wants your decision before it starts.

---

## Verification

Every phase re-runs both gates and must not move the counts unless noted:

- `just test-floodgate-dual-mode` — 38 Routerlicious + 7 Phoenix/cross-mode against one
  process, from `justfile:135`.
- `just test-levee-suite-vs-floodgate` — Levee's unmodified suites repointed at a
  containerised floodgate, from `justfile:100`. Baseline 53 of 54; the failure is the
  intentional 401-not-403 divergence.
- `gleam test` in `server/floodgate/` — 108 test functions across 8 files.
- `floodgate-readiness.json` — the repo-tracked release gate.

**Expected to move a count:** 3.1 (signal targeting) changes observable behaviour toward
Levee's. Anything else moving a count is a regression.

**New tests each phase needs:** a session-restart test (1.1), an abnormal-disconnect reclaim
test (1.2), a soak test for bounded growth (1.3), boundary tests at the size limit (2), a
three-client targeting test (3.1), a scan-independence benchmark (3.2), an origin-rejection
test (4.1), and a connection-ceiling test (4.2).

---

## Risks

- **1.1 is a public API change.** `Session` moves from carrying a Subject to carrying a name,
  which touches all ~18 call sites in `session.gleam` and anything holding a `Session`. It
  also affects `test/floodgate_test.gleam`, which starts sessions directly.
- **1.1's restart is not transparent to clients.** Sequence state rehydrates; client roster
  does not. Clients get nacked until they rejoin. Better than today, but it should be a
  deliberate, documented behaviour rather than a surprise.
- **1.3's op pruning changes observable API results** — `requestOps` and the deltas endpoints
  can still request pruned ops. Gate it, default off, land it last.
- **3.1 is the only item expected to change conformance results.** Land it alone so the
  delta is unambiguous.
- **Phase 2 is a protocol-visible decision either way** — either the enforced limit changes
  or the advertised one does.
- **4.2 could trip the conformance suites**, which open several concurrent connections from a
  single address. Defaults must be generous.
- **`server_codec`'s missing `close`** may be load-bearing by accident; check client
  behaviour before restoring it.

---

## Critical files

- `server/floodgate/src/floodgate.gleam:87-116` — the startup path: supervisor construction,
  the unsupervised `session.start_with_backend` at `:105`, and the discarded `beryl.register`
  result at `:106`
- `server/floodgate/src/floodgate/session.gleam:174-181` — `let assert Ok(s) = … actor.start`;
  `:188-371` the ~18 `process.call` sites; `:373-400` rehydration
- `server/floodgate/src/floodgate/socketio_transport.gleam:22-26,267,271` — handshake
  constants, disconnect path, the unconditional ping timer
- `server/floodgate/src/floodgate/document_channel.gleam:516,522` — the 16 MB advertisement;
  the signal fan-out and channel construction
- `server/floodgate/src/floodgate/shelf_store.gleam:55-65,96-106` — the two full scans
- `server/floodgate/src/floodgate/store.gleam:12-28` — the backend seam
- `beryl.gleam:253,287,320,355,479,1026` — the frame-cap default, `with_heartbeat`,
  `with_max_connections_per_ip`, `with_max_connections`, `with_max_inbound_frame_bytes`,
  `send_info`
- `beryl/coordinator.gleam:183,667,731` — the disabled heartbeat sweep
- `beryl/connection_limit.gleam:144,212` — the monitor-based reclaim pattern to copy
- `docs/adr/008-floodgate-phoenix-endpoint.md` — the deferred targeting and origin asymmetry
- `docs/adr/009-floodgate-standalone-repo.md` — the extraction blocker and the 401 decision
