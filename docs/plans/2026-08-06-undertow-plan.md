# Undertow — .NET Reimplementation of Floodgate

**Status:** Planned, not started · **Date:** 2026-08-06

**Undertow** is the name of the .NET implementation. Throughout this document,
"Floodgate" refers to the existing Gleam server being ported from; "Undertow" refers to
the .NET server being built. The two are wire-compatible peers, not successor and
predecessor — Gleam Floodgate keeps working.

## Context

Floodgate is a Fluid Framework-compatible collaborative document service written in Gleam
on the BEAM, living at `server/floodgate/` inside the Levee repo. One process serves two
wire protocols and a REST surface from one port, backed by one sequencer and one storage
layer.

We want a second implementation on .NET. This plan chooses that stack, with particular
attention to where the BEAM currently provides capabilities — process-per-connection,
actor mailboxes as serialization points, supervision, ETS/DETS, `pg` distribution — that
.NET must replicate by other means.

This is a **reimplementation, not a rewrite in place.** Gleam Floodgate keeps working, and
the existing TypeScript conformance suites become the shared executable specification both
servers are held to. Levee (Elixir) is untouched, and so are the Gleam protocol libraries —
`spillway`, `signet`, and `silt` remain in use by Levee and by Gleam Floodgate. In
particular, `spillway/schema.gleam` must **not** be deleted: `mix generate_schema` renders
it to `server/priv/protocol-schema.json`, which `just generate-schema-ts` copies into
`client/packages/levee-driver/schemas/`. The .NET port simply doesn't reimplement it.

### Decisions taken before planning

| Decision | Choice |
|---|---|
| Scope | **Floodgate only.** |
| Language | **F# domain/protocol tier, C# host/transport tier** — mirroring today's Gleam-domain / Elixir-host split. |
| Deployment | **Single node, cluster-ready seams.** One process, embedded storage; scale-out must be additive. |
| Compatibility | **Strict wire parity, both modes.** Existing conformance suites pass unmodified. |
| Runtime | .NET 10 (LTS to Nov 2028), F# 10. |

### Why the BEAM story is narrower than it looks

**Floodgate is single-node in practice.** One unsupervised actor holds sequence state for
*all* documents; topic→socket maps are plain dicts in one coordinator process; the
`pg`-based pub/sub is wired up but delivers nothing in the shipped single-process
deployment; and beryl's heartbeat eviction is **off** (`coordinator.gleam:183` defaults
`heartbeat_check_interval_ms: 0`, guarded at `:667` and `:731`), so the Engine.IO and
Phoenix heartbeats refresh a timer nobody reads. Levee isn't distributed either — its
architecture deck claims PubSub fan-out and CRDT presence, but the code sends to raw PIDs
in a node-local Registry.

So there is no distributed reference behaviour to port. Four things genuinely must be
replicated:

1. **Single-writer serialization per document** for sequence assignment.
2. **Per-connection outbound send serialization** — `WebSocket.SendAsync` is not
   concurrency-safe; the BEAM gets this free from the process mailbox.
3. **Handler-callback crash isolation**, so one malformed payload can't take down the
   shared coordinator.
4. **Lazy per-document rehydration** from storage on cache miss.

Droppable: `pg` distribution, the crash-survivable handler registry and its `RestForOne`
recovery ordering, named-process registration, `process.monitor`, the `make_table_public`
ETS hack, heartbeat eviction. Easier in .NET: per-socket targeted push (which the BEAM
version cannot do, leaving signal targeting parsed-but-ignored) and `finally`-based
teardown (Gleam leaks session membership if a connection dies without `on_close` firing).

**One structural simplification falls out.** Three of the Gleam session actor's message
variants carry closures (`CreateInitialized`, `SubmitMessage`, `SubmitSummaryMessages`)
so the wire message can be built *inside* the critical section and embed the just-assigned
SN/MSN atomically. Those closures exist only because sequencer state lived in a separate
process from the message-building code. With a per-document object guarded by a
per-document primitive, the handler runs inside the critical section and calls the pure
transition and the pure builder back to back. The closures disappear.

---

## Solution layout

```
Undertow.slnx
Directory.Build.props        # net10.0, Nullable, TreatWarningsAsErrors, InvariantGlobalization
Directory.Packages.props     # central package management
.editorconfig                # serves both dotnet-format and Fantomas
src/
  Undertow.Protocol/        F#   zero project references — FSharp.Core + BCL only
  Undertow.Abstractions/    C#   -> Protocol
  Undertow.Runtime/         C#   -> Abstractions, Protocol
  Undertow.Transports/      C#   -> Runtime
  Undertow.Storage.Memory/  C#   -> Abstractions
  Undertow.Storage.Sqlite/  C#   -> Abstractions
  Undertow.Server/          C#   -> all
tests/
  Undertow.Protocol.Tests/  F#   Expecto + FsCheck + YoloDev.Expecto.TestSdk
  Undertow.Storage.Tests/   C#   xunit, parameterized over backends
  Undertow.Server.Tests/    C#   xunit + WebApplicationFactory
tools/
  Undertow.WireDiff/        C#   Phase-0 recorder, later a shadow differ
```

`Undertow.Protocol` is **one** F# project with explicit `<Compile>` ordering mirroring the
Gleam module DAG — the file order *is* the dependency documentation. It holds spillway,
signet, silt, windsock, dewdrop events, the Socket.IO and Phoenix framing, RestLess
parsing, `initial_summary`, REST response shaping, **and the pure half of
`document_channel`**. Its zero-project-reference constraint is what keeps it pure; enforce
that in review. Expect ~3,500–4,500 lines of F# for ~5,000 of Gleam.

### The F#/C# boundary

**Rule: F# discriminated unions never cross. F# converts at its own edge.** Three shapes
and nothing else:

| Direction | Representation |
|---|---|
| Untyped inbound JSON → F# | `System.Text.Json.JsonElement` (the `Dynamic` analogue) |
| F# decisions → C# | F#-declared **records** with **enum** tags, arrays not `list`, no `option`, no `Result` |
| F# rendered output → C# | `ReadOnlyMemory<byte>` of UTF-8 JSON |

Provide a thin F# `Dyn` module mirroring the Gleam decode helpers (`Dyn.stringField`,
`Dyn.intField`, `Dyn.tryObject`) so the port is mechanical.

**`JsonDocument` is pooled and `IDisposable`.** A `JsonElement` retained past its
document's disposal silently reads freed memory. Rule: parse once per inbound frame, keep
the document alive for the whole handler via `using`, and `GetRawText()` anything retained
beyond it. Gleam already does this — op JSON is stored as strings.

**Where the split earns its keep.** Split `document_channel.gleam` rather than assigning it
wholesale: F# decides, C# orchestrates. Expressing effects as data turns the
connect-ordering contract into a transport-free unit test:

```fsharp
type EffectKind = BroadcastExceptSelf = 0 | Broadcast = 1 | InitialSignal = 2
type Effect = { Kind: EffectKind; Event: string; Payload: byte[] }
val decideConnectEffects : mode:string -> joinOp:Json -> presenceJoin:Json -> Effect[]
```

**Friction to expect.** Nullability is the real one: F# emits no C# nullable-reference
annotations, so make boundary types non-nullable by construction (empty string, not null;
empty array, not null — which matches Gleam's total-function style anyway), and use
`TryGet`-style out-parameters where a null is genuinely needed. Keep `option`/`Result`
internal. Convert `FSharpList` to arrays at the boundary. You need **Fantomas** alongside
`dotnet format` (both read `.editorconfig`). And **F# rules out NativeAOT** (FSharp.Core
reflection, `printf`) — use `PublishReadyToRun`.

---

## JSON strategy — contract-critical

An F# ordered-JSON AST plus `Utf8JsonWriter`. **Never `JsonSerializer`.**

```fsharp
type Json =
  | JNull | JBool of bool | JInt of int64 | JFloat of float | JStr of string
  | JRaw of ReadOnlyMemory<byte>   // the raw_json / preprocessed_array splice
  | JArr of Json list
  | JObj of (string * Json) list   // ORDER IS THE CONTRACT, visible in the source
```

This is `gleam/json` one-for-one, so `json.object([#("claims", …), …])` ports to
`JObj [ "claims", …; … ]` with zero thought, and the key-order contract stays where it is
in the original. With `JsonSerializer`, order becomes a function of member declaration
order, `[JsonPropertyOrder]`, naming policies, converter registration, and framework
version — four places to drift on a byte-exact contract.

Three load-bearing writer settings:

| Setting | Value | Why |
|---|---|---|
| `Encoder` | `JavaScriptEncoder.UnsafeRelaxedJsonEscaping` | STJ's default escapes `+ < > &` and **all non-ASCII** as `\uXXXX`; Erlang's `json:encode` emits raw UTF-8. An accented user name would produce different bytes. |
| `Indented` | `false` | assert it in a test |
| raw splice | `WriteRawValue(span, skipInputValidation: true)` | exact `raw_json` equivalent — splices stored op JSON with zero re-parse. This built-in is why STJ wins. |

Keep UTF-8 bytes end to end: assemble the `"42"` prefix and payload into one
`ArrayBufferWriter<byte>`, no `string` round-trip on the hot path.

### Canonicalization — the assert-`0x4b2` contract, demystified

`normalize_client_json` is a **recursive key sort**, not byte-identity voodoo: it round-trips
through an Erlang map, and `maps:to_list` on a flatmap (≤32 keys) returns keys in term
order, which for binaries is byte-wise lexicographic. So:

```fsharp
/// Equivalent of normalize_client_json: recursively sort JObj keys by UTF-8 ordinal.
val canonicalize : Json -> Json
```

Compare by **UTF-8 byte ordinal**, not `string.CompareOrdinal` — UTF-16 code-unit order
differs from UTF-8 byte order in the U+E000–U+FFFF vs. non-BMP range. Keys here are ASCII
so it never bites, but write it right once.

**Caveat:** above 32 keys Erlang map order becomes hash-dependent and .NET cannot
reproduce it. This cannot break assert `0x4b2` (both our paths agree with each other), but
it *will* break a golden fixture if a captured payload has such an object. Check the
Phase-0 captures.

Where to canonicalize:

| Site | Gleam | Recommend | Why |
|---|---|---|---|
| IClient (supplied + roster) | sort | **sort** | the 0x4b2 identity contract; non-negotiable |
| Sequenced op `contents`/`metadata` | sort (incidentally) | **raw passthrough** | faster, safer, and dodges Erlang-vs-STJ float formatting (`1.0` vs `1`). Fluid re-parses; order isn't semantic. |
| Signal `content` | sort | **raw passthrough** | same |
| Server-built objects (IConnected, nack, summaryAck, presence) | author order | **author order** | hand-write the `JObj` list in documented order |

The join op's embedded client payload is a JSON *string* (`client_join_data` stringifies
`{clientId, detail}`), so canonicalize `client` **before** stringification and the
join-op-vs-`initialClients` identity holds. Assert that explicitly.

---

## Concurrency design

**Per-document `SemaphoreSlim(1,1)` behind an async interface.**

```csharp
public interface IDocumentSequencer            // the cluster seam
{
    ValueTask<SequencedOpResult> SubmitOpAsync(string topic, string clientId, int csn, int rsn,
                                              ReadOnlyMemory<byte> contents, CancellationToken ct);
    ValueTask<ConnectResult> ConnectAsync(...);
}
```

`System.Threading.Lock` is rejected — it can't be held across `await`, so an async or
remote backend later forces a rewrite. A `Channel<T>`-fed actor loop is rejected more
firmly: it's the closest analogue to the Gleam actor and it *recreates the awkwardness we
just removed* (a `TaskCompletionSource` per call, closures to build inside the section) to
buy crash isolation that `try/finally` already gives. `ValueTask` on a
synchronously-completing single-node implementation costs nothing and is the seam.

**The critical section, in order:**

```
await sem.WaitAsync(ct);
try {
    1. pure F#: assignSequenceNumber (validation order UnknownClient -> InvalidCsn -> InvalidRsn)
    2. pure F#: build sequenced-op bytes with the just-assigned SN/MSN
    3. ONE storage transaction: INSERT op + UPDATE checkpoint WHERE version = @expected
    4. TryWrite frames to each target socket's bounded outbound Channel
    5. commit the new in-memory SequenceState
} finally { sem.Release(); }
```

**Step 4 must be inside the lock.** Release first and two concurrent ops can interleave so
a socket sees SN 8 before SN 7. `TryWrite` on a bounded channel is lock-free, so it costs
nothing under the lock. This is the ordering detail most likely to be missed, and it only
fails under concurrency — the conformance suite may well pass without it. Equally: step 4
must **never block**. `TryWrite` only; on failure (bounded channel full = slow consumer),
mark for eviction and continue. Never `await WriteAsync` under a document lock.

Step 3 inside the section matches Gleam and gives durable-before-broadcast; with SQLite WAL
and `synchronous=NORMAL` a local append is tens of microseconds.

**Per-socket outbound.** Each `SocketConnection` owns a
`BoundedChannelOptions(1024) { FullMode = DropWrite, SingleReader = true }` plus one pump
task doing the `SendAsync`. Bounded-and-evict, not unbounded: one wedged browser tab
shouldn't OOM the server. On drop, close with 1011 — Fluid clients reconnect and catch up
via `requestOps`, so eviction is cheap and correct.

**Crash isolation.** Wrap every handler callback in `try/catch`, log with
topic+socketId+event, terminate only that socket's channel membership (Phoenix: `phx_error`;
Socket.IO: silence — see the `close`-encoder note below). Never let it escape into the
transport read loop or leak a held semaphore.

**Registry and lifetime.** `ConcurrentDictionary<string, Lazy<Task<DocumentSession>>>` keyed
by topic — the `Lazy` gives exactly-once async rehydration when two connects race a cold
document. Note Gleam never evicts documents and loads the full op history into memory per
document, unbounded on both axes. Don't copy that: keep no in-memory op history (serve
`requestOps` and deltas from the indexed range query) and add idle eviction once parity is
green.

---

## The channel coordinator (~700 lines)

```
Undertow.Runtime/
  SocketConnection.cs   ~130   id, WebSocket, outbound Channel, pump, codec, channel instances
  SocketRegistry.cs     ~120   socketId -> connection ; topic -> ImmutableHashSet<socketId>
  ChannelDispatcher.cs  ~170   join / handle_in / terminate, duplicate-join replacement, guards
  ChannelContext.cs      ~60   SocketId, Topic, JoinRef, Assigns, IChannelBroadcaster
  IChannelHandler.cs     ~40
  DocumentSession.cs    ~180   per-document semaphore + SequenceState + checkpoint commit
  DocumentRegistry.cs    ~80
```

```csharp
public sealed record JoinOutcome(bool Ok, ReadOnlyMemory<byte> Reply, bool HasReply, object? Assigns);
public interface IChannelBroadcaster {
    void Broadcast(string topic, string @event, ReadOnlyMemory<byte> payload);
    void BroadcastFrom(string exceptSocketId, string topic, string @event, ReadOnlyMemory<byte> payload);
    void Push(string socketId, string topic, string @event, ReadOnlyMemory<byte> payload);
}
```

`HasReply` is a separate bool, not a nullable, because the Phoenix two-phase join replies
`ok` with an **empty** payload — distinct from "no reply". Conflating them is a silent
Phoenix-join failure.

**Socket IDs only above the registry**, per the cluster-ready decision. No `WebSocket` or
`SocketConnection` appears in any signature above `SocketRegistry`; the topic map is
explicitly local-only. Scale-out later is a `LocalBroadcaster` + `ITopicBus` composite with
no change to the domain or channel tiers.

Encoding is **per socket**, not once per broadcast — the two transports frame differently
and `op`/`nack` need the documentId spliced for Socket.IO. Payload bytes are shared
(immutable `ReadOnlyMemory<byte>`); only the ~40-byte wrapper is per socket.

**Assigns:** `ConcurrentDictionary<string /*topic*/, ChannelInstance>` per socket, matching
beryl. Socket.IO uses one; Phoenix may join several.

**Two beryl behaviours that must be ported** — this is the one place the "discard beryl"
call was incomplete:

- **Duplicate join replaces.** `coordinator.gleam:1192` calls
  `replace_existing_then_join` (`:1211`): re-joining an already-joined topic terminates the
  old channel instance *first*, which runs `on_leave` → for `mode:"write"` that **emits a
  sequenced leave op** before the rejoin. Easy to miss; produces a spurious leave/join op
  pair a container will notice.
- **Reject client-supplied `phx_*` events** before they reach the handler.

Plus length/depth guards: max topic length, max event length, and `JsonReaderOptions.MaxDepth`
set explicitly to match beryl's `max_json_nesting_depth`.

---

## The two transports

Raw `HttpContext.WebSockets`. Not SignalR — its protocol is incompatible and its hub
abstraction hides the frame bytes we must control.

**Cross-cutting: fragmentation.** `mist` reassembled messages; Kestrel does not.
`ReceiveAsync` returns `EndOfMessage == false` for fragments and its default buffer is 4 KB,
so a 16 MB op arrives as thousands of fragments. Write one shared reader accumulating into
a pooled `ArrayBufferWriter<byte>` with a hard cap (close 1009 on breach). Three different
limits must all be honoured: `maxMessageSize: 16777216` in IConnected, `maxPayload: 1000000`
in the Engine.IO handshake, and the 4 MB REST body cap (`mist.read_body(req, 4_000_000)`).

### `/socket.io/` — Engine.IO v4 / Socket.IO v5

Match `/socket.io` and `/socket.io/`; ignore (don't validate) `EIO`, as Gleam does. On
upgrade send `0{"sid":…,"upgrades":[],"pingInterval":25000,"pingTimeout":20000,"maxPayload":1000000}`,
register, start a 25 s ping timer. `"2"`/`"3"` → Heartbeat; `"40"` → reply `40{"sid":…}`;
`42[...]` → decode; anything else → **ignore silently**. The ping timer is unconditional and
**never times out on a missing pong** — replicate, and comment the spec divergence.

Positional-args → payload-object translation, with the **sticky per-socket topic** learned
from `connect_document`:

| event | args | becomes |
|---|---|---|
| `connect_document` | `[payload]` | Join, topic `document:{payload.tenantId}:{payload.id}` (empty ⇒ drop) |
| `submitOp` | `[clientId, batches]` | `{clientId, messageBatches}` on the sticky topic |
| `submitSignal` | `[clientId, signals]` | `{clientId, signals}` on the sticky topic |
| anything else | `[payload, …]` | `payload` on the sticky topic |
| any of the above with sticky topic `""` | | **drop** |

Outbound `op` and `nack` are **two-arg** (`42["op","<documentId>",[msgs]]`), documentId from
the topic's third segment; everything else one-arg. Enforce in the codec's type signature,
as `socketio.gleam` does. **No origin check** on this path today — leave it off and note it
as a decision, not an oversight.

`clientId` is `base16_encode(16 random bytes)` = 32 **uppercase** hex, which
`Convert.ToHexString(RandomNumberGenerator.GetBytes(16))` matches exactly.

### `/socket/websocket` — Phoenix Channels V2

`vsn` gate: reject unless it starts with `"2."` (HTTP 400 before upgrade). Origin/CSWSH
policy from `UNDERTOW_ALLOWED_ORIGINS` (`*` = allow all, comma-separated otherwise,
missing = deny cross-origin), rejected with 403 before upgrade. **Do not use ASP.NET CORS
middleware** — CORS does not govern WebSockets; relying on it is the classic CSWSH hole.

Frames are `[join_ref, ref, topic, event, payload]`. `phx_join` → Join; `phx_leave` → Leave;
`heartbeat` → Heartbeat **only on topic `"phoenix"`**, otherwise a normal event — that last
distinction is easy to miss. Replies `[join_ref, ref, topic, "phx_reply", {status, response}]`;
pushes `[null, null, topic, event, payload]`; `phx_close`/`phx_error` mirror `join_ref` into
the `ref` slot. Two-phase join: `phx_join{token}` authorizes topic+token and replies `ok`
with empty payload (`HasReply=true`), assigns `connected=false`; then `connect_document`
**pushes** `connect_document_success`/`_error` — not a `phx_reply`.

---

## Storage

**SQLite via `Microsoft.Data.Sqlite`, WAL mode.** Single file, real indexes, real
transactions (giving cross-table atomicity the Gleam version can't express), and
`SQLitePCLRaw.bundle_e_sqlite3` bundles the native lib so a chiseled container needs
nothing extra. LiteDB is rejected (weaker concurrency, no SQL for the composite range
scans); RocksDB/FASTER/LMDB rejected (native deps plus hand-rolled composite-key
encoding); EF Core rejected (change tracker and migrations over six trivial tables).

```sql
PRAGMA journal_mode = WAL;  PRAGMA synchronous = NORMAL;  PRAGMA busy_timeout = 5000;

CREATE TABLE documents  (topic TEXT PRIMARY KEY, created_at INTEGER NOT NULL);
CREATE TABLE ops        (topic TEXT NOT NULL, sequence_number INTEGER NOT NULL,
                         payload TEXT NOT NULL,
                         PRIMARY KEY (topic, sequence_number)) WITHOUT ROWID;
CREATE TABLE summaries  (topic TEXT PRIMARY KEY, handle TEXT NOT NULL,
                         sequence_number INTEGER NOT NULL);
CREATE TABLE checkpoints(topic TEXT PRIMARY KEY, sequence_number INTEGER NOT NULL,
                         minimum_sequence_number INTEGER NOT NULL,
                         version INTEGER NOT NULL,        -- the etag
                         updated_at INTEGER NOT NULL);
CREATE TABLE objects    (tenant TEXT NOT NULL, sha TEXT NOT NULL, body TEXT NOT NULL,
                         PRIMARY KEY (tenant, sha)) WITHOUT ROWID;
CREATE TABLE refs       (tenant TEXT NOT NULL, path TEXT NOT NULL, sha TEXT NOT NULL,
                         PRIMARY KEY (tenant, path)) WITHOUT ROWID;
```

The `ops` PK replaces Gleam's full scan for both `get_ops` and `since(topic, from)`; the
`refs` PK gives `list_refs` its ordered scan. Both `WITHOUT ROWID` because the PK *is* the
access path. Note the key asymmetry inherited from Gleam: ops and summaries are keyed by
document **topic**, objects and refs by **tenant**.

Two interfaces rather than one 13-method record — `IDocumentStore` and `IGitObjectStore`.
The design point is:

```csharp
/// Single transaction: append ops + advance checkpoint under optimistic concurrency.
/// False when expectedVersion no longer matches (another writer exists).
ValueTask<bool> CommitSequencedAsync(string topic, OpRecord[] ops, CheckpointRecord next,
                                     long expectedVersion, CancellationToken ct);
```

On a single node the false branch never fires; it is the entire multi-writer safety story
and costs one `WHERE` clause today. **This is the one thing painful to retrofit** — hence
designing it in now.

**Cold start must reproduce Gleam's `from_checkpoint(max(maxOpSn, summarySn), summarySn)`**
(`session.gleam:373-399`). When `LoadCheckpointAsync` returns null, fall back to
`SELECT MAX(sequence_number) FROM ops WHERE topic=?` plus the summary row and synthesize a
checkpoint at version 0. That makes the checkpoint a pure rebuildable cache, so the table
can ship empty.

**One deliberate divergence to gate:** Gleam restores MSN from the *summary* SN, discarding
the live MSN. Storing the live MSN is strictly more accurate and monotonicity still holds;
no conformance test restarts a server mid-document. Gate it behind
`UNDERTOW_COMPAT_RESTORE_MSN_FROM_SUMMARY=1`.

**Historian fetches — kill the N+1 before it exists.** `silt/rest.gleam` takes a
`Fetch = fn(sha) -> Result(String, Nil)` callback and recursively flattens trees to depth
64. Ported literally that's synchronous IO reaching into the pure F# tier plus N+1 queries.
Instead, C# pre-loads the transitive closure (batched `WHERE sha IN (…)`, or a recursive
CTE) and hands F# an `IReadOnlyDictionary<string,string>`: the callback becomes a pure
lookup, F# stays pure by signature, and the request is O(depth) round-trips.

**Do not unify the two hashing schemes.** Blobs are git-canonical
`SHA1("blob " + byteLen + "\0" + content)`; trees and commits are `SHA1(serialized JSON body)`,
*not* git-canonical. It looks like a bug; it is the contract — existing stored commits and
refs hash that way. Comment and test each.

For the eventual distributed case: `ops` becomes a topic-partitioned append-only log,
`checkpoints` maps onto a native etag (Cosmos `_etag`, Azure Table `ETag`, Redis version
field), objects go to a blob store, and `refs` needs a real compare-and-set (`TryCreateRef`
already is one). `expectedVersion` is the whole seam; nothing above `IDocumentStore` changes.

---

## Auth

**Register no authentication or authorization middleware at all.** Stock `JwtBearer` is
wrong here for five concrete reasons:

1. **Three token forms** — `Bearer <jwt>`, Routerlicious `Basic base64(user:jwt)`, and bare
   `Basic <jwt>`. `JwtBearerHandler` reads only the first.
2. **401 for everything, with exact message bodies.** ADR-009 pins 401 deliberately: 401
   makes a Fluid client refresh and retry, 403 is fatal. ASP.NET's authorization pipeline
   emits **403** with an empty body for authenticated-but-unauthorized — fighting the
   framework on the one axis that must not move.
3. **Route-param↔claim cross-checks**, including tenant-write *without* binding a document
   (the `POST /documents/:tenant` case).
4. **The default 5-minute `ClockSkew`** would make expiry tests pass that should fail.
5. **The socket path** carries the token as a payload field, not a header, and needs one
   verification function shared by both surfaces.

Build an F# `Signet` module (pure, total) plus a C# `Authorization` static class with six
functions mirroring the six `authorize_*` helpers, called explicitly at the top of each
endpoint handler exactly as the Gleam router does — that structural parallel is what makes
the port reviewable line by line.

Implementation notes: **HS256 only** (reject any other `alg`, including `none` —
algorithm-confusion); `System.Buffers.Text.Base64Url` handles **unpadded** base64url
natively, so don't hand-roll padding; `HMACSHA256.HashData` +
`CryptographicOperations.FixedTimeEquals`; `ver` must equal exactly `"1.0"`; preserve the
composition order (expiration → tenant → document) because the *message* differs by which
check fires first and the tests read messages. Avoid
`System.IdentityModel.Tokens.Jwt`/`Microsoft.IdentityModel.JsonWebTokens` entirely.

The known-failing test — `rest-api.test.ts` "rejects requests with insufficient scopes"
wants 403 — **is supposed to fail.** Pin it with an explicit test asserting 401 and a
comment citing ADR-009.

**REST router:** Minimal APIs, one static class per route family. ASP.NET routing gets
precedence right (literals beat parameters). Validate `{kind}` ∈ `blobs|trees|commits`
**in the handler**, not via route constraint, so an unknown kind 404s as the Gleam `case`
does. `/health` is hand-written to return exactly `{"status":"ok"}` for GET **and HEAD** —
do not use `AddHealthChecks()`, whose default body is the plain text `Healthy`.

**RestLess must be terminal middleware before `UseRouting()`**, because it changes the
request method and routing has already run by the time an endpoint filter sees it.
`Content-Type` containing `;restless` → read body (4 MB cap), parse the query string, apply
`method=`, apply each `header=Name: Value` (lowercasing the name), replace `Request.Body`
with a `MemoryStream` over `body=`. Gleam stashes it in a header because `mist` bodies
aren't rewindable; .NET can replace the stream properly — just update `Content-Type` and
`Content-Length` to match.

**Config comes from env vars read explicitly at startup**, not through `IConfiguration`'s
`ASPNETCORE_`/`DOTNET_` conventions or appsettings. The surface mirrors Floodgate's one
for one: `PORT` (wins over `UNDERTOW_PORT`), `UNDERTOW_PORT`, `UNDERTOW_BIND`,
`UNDERTOW_TENANT_ID`, `UNDERTOW_JWT_SECRET` (unset ⇒ hard startup failure),
`UNDERTOW_TOKEN_MINT_SECRET`, `UNDERTOW_TOKEN_MINT_USER_ID`,
`UNDERTOW_TOKEN_MINT_USER_NAME`, `UNDERTOW_PUBLIC_URL`, `UNDERTOW_ALLOWED_ORIGINS`,
`UNDERTOW_STORAGE_BACKEND`, `UNDERTOW_DATA_DIR`, plus the limit vars
(`UNDERTOW_MAX_FRAME_BYTES`, `UNDERTOW_MAX_CONNECTIONS[_PER_IP]`,
`UNDERTOW_MESSAGE_RATE`/`_BURST`, `UNDERTOW_JOIN_RATE`/`_BURST`).

**Env var names are not part of the wire contract** and carry no compatibility
obligation — they are a deployment interface, and every file that sets them
(`docker-compose.yml`, `Dockerfile`, the `justfile` recipes) is ours. What the
conformance suites actually require is that the *value* the suite signs with matches the
value the server verifies with, not that the two sides spell the variable the same way.

One transitional convenience: **each key falls back to its `FLOODGATE_*` spelling when
the `UNDERTOW_*` one is unset.** This is purely so the Phase-0 shadow differ can drive
both binaries from a single compose file with only `image:` changed. It is a dozen lines
in the config reader, and it should be deleted once the differ retires. Precedence is
`UNDERTOW_*` → `FLOODGATE_*` → default, and startup logs which spelling supplied each
value so a stale `FLOODGATE_*` can't silently win.

The TS suites keep their own `FLOODGATE_*` variables (`FLOODGATE_HTTP_URL`,
`FLOODGATE_SOCKET_URL`, `FLOODGATE_TARGET_LABEL`, …). Those are read by
`floodgate-target.ts` to decide what to point at and what to sign with; they name the
*suite*, not the server, and are independent of what the server under test calls its own
config. Adding Undertow means adding a target label, not renaming them.

**Two default *values* must stay byte-identical**, because they reach clients through JWT
claims and the resulting `IConnected` payload: `UNDERTOW_TOKEN_MINT_USER_ID` defaults to
`"floodgate-token-mint"` and `UNDERTOW_TOKEN_MINT_USER_NAME` to `"Floodgate Token Mint"`.
These are wire-observable, so the shadow differ will flag any change. They are values, not
names — leave them alone regardless of what the project is called.

---

## Testing strategy

**F# unit suite (Expecto + FsCheck + YoloDev.Expecto.TestSdk).** Port spillway/test (381),
signet/test (316), silt/test (201), plus floodgate's own Gleam tests — Expecto's
`testList`/`testCase` maps mechanically onto gleeunit's style, and the TestSdk adapter gives
`dotnet test` and IDE integration. Add FsCheck properties: SN strictly increasing; MSN never
decreases across *any* interleaving of join/leave/submit/noop; validation order is exactly
UnknownClient → InvalidCsn → InvalidRsn.

**Golden wire fixtures.** Recorded from the Gleam server in Phase 0. Exact string equality
against `.txt` files — explicitly **not** Verify/snapshot libraries, which pretty-print and
scrub JSON by default and would destroy the signal being tested. Covers IConnected,
sequenced op, nack, summaryAck, presence join/leave, Engine.IO open, Socket.IO connect ack,
`phx_reply`, `phx_close`, plus the 0x4b2 identity test and a
`user.name = "Ünïcödé <&>"` escaper test.

**Storage backend conformance.** Abstract xunit base parameterized over Memory,
SQLite-on-disk, and SQLite-in-memory, mirroring the Gleam backend-substitution test's "two
backends produce identical observations" property (existing, roster, initial ops, summary,
current SN, deltas JSON, blob JSON) — then strengthen it with FsCheck generating a random
operation sequence both backends replay. Add explicit cases for the topic-vs-tenant key
asymmetry and for ref-path normalization (`heads/main` ≡ `refs/heads/main`), the single most
likely silent storage bug.

**In-process integration.** `WebApplicationFactory<Program>` +
`TestServer.CreateWebSocketClient()` drives real handshakes with no ports and full
debuggability. Pin here: two-phase Phoenix join, connect-time op/signal ordering per mode,
MSN + noop advance, duplicate-join replacement, read-mode nack, `submitOp` before connect.
Inject `TimeProvider` (`FakeTimeProvider`) for deterministic timestamps, plus a one-liner
asserting every emitted timestamp is `≡ 0 (mod 1000)` (Gleam emits `now_seconds() * 1000`).

**The TS conformance gate (acceptance).** Mirror the Gleam `just` recipes; they need only
env vars. Reuse the existing readiness probe (POST `/api/tenants/fluid/token-mint` until
200) rather than `/health`, matching `justfile:163`.

**Shadow differ (`tools/Undertow.WireDiff`).** The highest-leverage tool here. Run Gleam on
:3000 and .NET on :3001, drive both with the same recorded script, diff frame streams. This
converts "7 of 38 tests fail" into "byte 412 of IConnected differs: `scopes` before
`documentId`". Build the recorder in Phase 0, extend to a differ in Phase 4.

---

## Build / CI / container

Two-stage Dockerfile mirroring the Gleam one: `sdk:10.0` builder with a restore layer before
sources, `dotnet publish -p:PublishReadyToRun=true` (**not** NativeAOT — F# doesn't survive
it), then `aspnet:10.0-noble-chiseled` runtime. `ENV UNDERTOW_DATA_DIR=/data PORT=3000
UNDERTOW_BIND=0.0.0.0 UNDERTOW_TENANT_ID=fluid`, `mkdir /data && chown $APP_UID`,
`VOLUME ["/data"]`, `UNDERTOW_JWT_SECRET` deliberately unset.

Two deliberate deviations, both improvements: the chiseled image has no shell or `wget`, so
**HEALTHCHECK uses a `--healthcheck` argv mode** — a ~15-line branch that GETs
`http://127.0.0.1:{PORT}/health` and exits 0/1 (`127.0.0.1`, not `localhost`, for the same
IPv4 reason the Gleam Dockerfile documents). This is on the critical path:
`docker compose up --wait` and the drop-in parity recipe both depend on it.

`docker-compose.yml` copies the Gleam one, changing the image name and the `UNDERTOW_*`
env keys. While the shadow differ is live the `FLOODGATE_*` fallback above means one
compose file can drive either binary with only `image:` swapped.

CI, three jobs: **lint** (`dotnet format --verify-no-changes` + `fantomas --check`), **test**
(`dotnet build -warnaserror`, `dotnet test`, `dotnet list package --vulnerable`), and
**conformance** (build image, `docker compose up -d --wait`, run both TS suites, publish
pass counts). Gate merges on the counts matching the recorded baseline so a regression is
loud.

---

## Phased sequence

| Phase | Work | Milestone |
|---|---|---|
| **0** | Skeleton; `WireDiff` **recorder**; capture golden fixtures from the running Gleam server; record baseline pass counts | Gleam baseline reproduced (38 + 7; 53/54). `tests/fixtures/wire/` committed. **Do not skip — the reference disappears after the port.** |
| **1** | F# `Json` AST + `canonicalize` + `toUtf8`; spillway sequencing/types/message/nack/validation; signet | spillway + signet suites green (~700 LOC of Gleam tests). MSN-monotonicity property green. |
| **2** | `IDocumentStore`/`IGitObjectStore`; Memory + SQLite; etag'd checkpoint; silt | Backend-substitution suite green across three backends. silt suite green. |
| **3** | ASP.NET host, env config, RestLess middleware, six `authorize_*`, full REST router, Historian with pre-loaded closure | `rest-api.test.ts` passes (minus the known 403). `/health` byte-exact. Container builds, `--healthcheck` works. |
| **4** | Coordinator (registry, dispatch, per-socket pump, duplicate-join replacement); Phoenix codec + vsn/origin gate; two-phase join; document sessions + semaphore + `CommitSequencedAsync`; extend WireDiff into a differ | `connection.test.ts` + `levee-client` suite green. Phoenix half of the 7 cross-mode tests. |
| **5** | Socket.IO transport: handshake, ping timer, sticky topic, positional-args translation, one-phase join, two-arg framing, connect-time ordering per mode | **38 Routerlicious tests pass.** Headline milestone. |
| **6** | Summaries: `submitSummary` nack path, sequenced `summarize`, `summaryAck` with reserved SN, `initial_summary` (two shapes × two layouts) | `levee-example/container.test.ts` green (the 0x4b2 case) + `floodgate-readiness.test.ts`. |
| **7** | Signals v1/v2 normalization + targeting parse; `noop` RSN advance; leave ops/signals | Presence-tracker and todo-list suites green. **Full 38 + 7 green.** |
| **8** | Container hardening, CI conformance job, `just` recipes, compose | **53/54 on the repointed Levee suite** (the 1 is the intentional 401). CI gates on counts. |
| **9** | Post-parity: idle eviction, backpressure tuning, op pruning below the last summary, signal-targeting flag flip, OpenTelemetry | No regression; memory bounded under soak. |

Phoenix (4) precedes Socket.IO (5) deliberately even though Socket.IO is the bigger prize:
Phoenix's two-phase join exercises the coordinator's join/reply/push paths *separately*,
whereas Socket.IO fuses them, so coordinator bugs localize more easily against Phoenix first.

---

## Verification

The acceptance gate already exists and is stack-agnostic.

**Dual-mode conformance** — 38 Routerlicious + 7 Phoenix/cross-mode against one process,
including a Socket.IO client and a Phoenix client collaborating on one document. Env:
`FLOODGATE_HTTP_URL` (default `http://localhost:3000`), `FLOODGATE_SOCKET_URL`,
`FLOODGATE_TENANT_ID` (default `fluid`), `FLOODGATE_JWT_SECRET`,
`FLOODGATE_TOKEN_MINT_SECRET`, `FLOODGATE_ROUTERLICIOUS_COMPAT`, `FLOODGATE_TARGET_LABEL`.
`just test-floodgate-dual-mode` hardcodes `gleam run` at `justfile:151` — add a .NET variant.

**Drop-in parity** — Levee's *own* unmodified suites (`levee-driver`, `levee-client`,
`levee-example`) repointed via `LEVEE_HTTP_URL=http://localhost:3000`,
`LEVEE_SOCKET_URL=ws://localhost:3000/socket`, `LEVEE_TENANT_KEY`. Nothing in them is
Floodgate-aware, so a failure is a real behavioural difference. Elixir baseline 54 passed;
Gleam Floodgate 53 + 1 known divergence.

**Release gate** — `floodgate-readiness.json` requires categories
create/load/sync/reconnect/summaries/signals across backends `["ets","memory"]` with
`expectedOutstandingTodoCount: 0`; the test fails the build if reality drifts. The `ets`
label maps to the SQLite backend.

---

## Risks

**Underestimated:**

1. **`spillway/signals.gleam` is 596 LOC** — larger than the sequencer, and the most
   dangerous module in the port, because signals are fire-and-forget. A subtly wrong field
   in a normalized v2 signal produces no error, no nack, and no failing test — just presence
   that quietly doesn't work in one client stack. Back it with Phase-0 fixtures for every
   capturable signal shape.
2. **WebSocket fragmentation and the three size limits.**
3. **The `existing` flag** is a three-way OR (`has_document || ops != [] || summary_handle != ""`).
   It drives container load-vs-create directly; simplifying it wrongly produces "container
   loads empty" bugs that look like storage bugs.
4. **Duplicate-join replacement emitting a leave op.**
5. **Enqueue-under-the-document-lock** — the bug it prevents appears only under concurrency,
   so the suite may pass without it and then fail intermittently under soak.

**Open questions to settle during implementation:**

- **Phoenix binary framing** — does `levee-driver` ever send binary frames? Floodgate wires
  `route_binary` through. If not, accept-and-log rather than porting beryl's binary codec.
- **`initial_summary.gleam` (382 LOC) was not read in detail.** ADR-009 divergences 6 and 7
  live there; it's the highest-complexity pure module after signals. Capture fixtures for all
  four combinations in Phase 0.
- **`>32-key` objects** in the Phase-0 captures (see the canonicalization caveat).
- **`server_codec.gleam` rebuilds the codec with `codec.new(...)`, dropping dewdrop's `close`
  encoder** — so Floodgate never emits `42["close"]` on graceful channel end. Latent bug;
  replicate the silence for parity, then decide.

**Two decisions wanted before Phase 7:**

1. **Per-client signal targeting.** `determine_signal_recipients` is fully implemented and
   fully ignored, because beryl has no per-socket push. .NET has it free. Recommendation:
   build the plumbing but ship behind `UNDERTOW_SIGNAL_TARGETING=0` (default off =
   broadcast everything), preserving strict parity for the gate, then flip in Phase 9 with
   the suites green as a control.
2. **Op contents: canonicalize or pass through.** Recommending passthrough — faster, safer,
   dodges Erlang-vs-STJ float formatting. But it is a documented byte-level divergence for
   any op whose contents has unsorted keys. The Phase-0 fixtures will show whether that case
   occurs; decide then.

---

## Critical files

- `server/floodgate/src/floodgate/document_channel.gleam` (1202) — the protocol brain;
  source of the F#/C# split, the ordering contract, and the top risks
- `server/floodgate/src/floodgate/session.gleam` (888) — closure-carrying `Msg` variants,
  `stored_message_json`/`raw_json`, and the rehydration semantics at `:373-399` the etag'd
  checkpoint must reproduce
- `spillway/src/spillway/sequencing.gleam` (274) — port target for the F# sequencer:
  validation order and MSN monotonicity
- `spillway/src/spillway/signals.gleam` (596) — the highest-risk module
- `server/floodgate/src/floodgate.gleam` (1003) — REST router, six `authorize_*`,
  `normalize_restless_request` (`:906`), full env-var surface
- `server/floodgate/src/floodgate/initial_summary.gleam` (382) — two input shapes × two
  root-tree layouts
- `beryl/packages/beryl/src/beryl/coordinator.gleam` — reference for the C# coordinator,
  specifically `replace_existing_then_join` (`:1211`) and the confirmed-disabled heartbeat
  (`:183`)
- `docs/adr/009-floodgate-standalone-repo.md` — the nine divergences as a checklist, and the
  deliberate 401 decision
- `justfile:100-170` — the conformance recipes to mirror
