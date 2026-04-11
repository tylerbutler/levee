# ADR-001: Public ETS access for levee_storage tables

- **Status:** Accepted
- **Date:** 2026-04-11
- **Context:** Shelf dependency update from 3a756bf to e92d136

## Context

Levee uses [shelf](https://github.com/tylerbutler/shelf) for persistent ETS/DETS storage. The `levee_storage` module opens shelf tables in a GenServer's `init/1` and stores the handles in `persistent_term` so that any process (Phoenix controllers, WebSocket channels, the Session GenServer) can read and write directly without routing through the owning GenServer.

Shelf changed its ETS table creation from `public` to `protected` access mode. In Erlang, `protected` means only the process that created the table can write; any process can read. This broke levee's cross-process write pattern — all writes returned `NotOwner` errors.

### levee_auth (not affected by this decision)

The `session_store` already follows shelf's intended pattern: a Gleam actor owns the tables and serializes all reads and writes through its message handler. The fix was to move `init_tables` into the actor's initializer so the actor process (not the Elixir supervisor) is the ETS owner. No access mode workaround needed.

### levee_storage (this decision)

The storage layer's tables are accessed from many processes. Routing all writes through a single GenServer would serialize all storage operations, adding latency and creating a throughput bottleneck for a real-time collaboration server.

## Decision

After opening shelf tables in `levee_storage/ets.gleam`, replace each `protected` ETS table with a `public` clone via an Erlang FFI helper (`make_table_public/1`). This restores the pre-upgrade behavior where any process can read and write.

### Why this is acceptable

Per-document write serialization is already enforced at a higher layer. Each document has a dedicated `Levee.Documents.Session` GenServer that processes all client operations sequentially. The request flow is:

```
Client → WebSocket Channel → Session GenServer → Storage (ETS write)
```

The Session GenServer is the single writer for a given document's data. Concurrent writes to *different* documents touch different ETS keys and don't conflict (ETS guarantees atomicity of individual operations).

### Known risks

1. **Read-modify-write races.** Functions like `update_document_sequence` and `update_ref` do `lookup` then `insert` without locking. If two processes call these for the same key concurrently, last-write-wins. This is safe today because the Session GenServer serializes per-document mutations, but would become a bug if a new code path writes to storage outside the Session.

2. **Fragile FFI.** The `make_table_public` helper reaches into shelf's opaque `PSet` tuple to extract the ETS reference (element 2). This breaks if shelf changes its internal representation. Tracked in [shelf#49](https://github.com/tylerbutler/shelf/issues/49) — if shelf adds a configurable access mode, this workaround can be removed.

3. **Save/close ownership.** Shelf's `save` and `close` operations are also owner-only. These are called from the `GleamETS` GenServer (which is the ETS owner), so they work correctly. If save/close were ever called from another process, they would fail.

## Alternatives considered

### Route all writes through the GenServer

The architecturally "correct" approach per shelf's design. Every storage mutation would become a `GenServer.call`, serializing all writes through one process.

**Rejected because:**
- Adds ~50-100μs per operation (message send + receive + scheduling)
- Serializes ALL writes (across all documents and tenants) through one process, creating a bottleneck
- The real concurrency protection already exists at the Session layer
- Would require significant refactoring of the storage module and all callers

### Transfer table ownership per-write

Use `ets:give_away/3` to transfer ownership to the writing process, then transfer back.

**Rejected because:**
- Impractical — ownership transfer requires cooperation from both processes
- Would serialize worse than the GenServer approach

### Wait for shelf to add access mode config

Do nothing and wait for [shelf#49](https://github.com/tylerbutler/shelf/issues/49).

**Rejected because:**
- Blocks the shelf upgrade on an upstream change with no timeline
- The FFI workaround is small and contained

## Consequences

- Storage writes from any process continue to work as before the shelf upgrade.
- A comment in `levee_storage/ets.gleam` documents the assumption that per-document writes are serialized by the Session GenServer.
- If a new code path needs to write to storage outside the Session GenServer, it must either serialize writes through its own process or this decision must be revisited.
- When shelf ships a configurable access mode ([shelf#49](https://github.com/tylerbutler/shelf/issues/49)), the `make_table_public` FFI workaround should be replaced with the native config option.
