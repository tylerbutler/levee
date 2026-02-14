# Beryl Standalone Channels Library Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Extract beryl into a standalone, generic Gleam channels library with Presence (CRDT), PubSub (pg), and Channel Groups — removing all levee-specific code from beryl itself.

**Architecture:** Beryl is currently ~90% generic channels infrastructure and ~10% levee-specific document protocol. We'll move levee-specific code into levee proper (new `levee_channels` Gleam package), then add Presence, PubSub, and Groups as new beryl modules. The coordinator actor gains hooks for presence and pubsub integration.

**Tech Stack:** Gleam (targeting Erlang/BEAM), OTP actors, Erlang `pg` module for distributed PubSub, CRDT-based presence tracking

---

## Phase 1: Extract Levee-Specific Code

### Task 1: Create levee_channels Gleam package

**Files:**
- Create: `levee_channels/gleam.toml`
- Create: `levee_channels/src/levee_channels.gleam`
- Create: `levee_channels/test/levee_channels_test.gleam`

**Step 1: Create the package directory and gleam.toml**

```bash
mkdir -p levee_channels/src levee_channels/test
```

`levee_channels/gleam.toml`:
```toml
name = "levee_channels"
version = "0.1.0"
description = "Levee document protocol channel handlers for beryl"
licences = ["Apache-2.0"]
gleam = ">= 1.1.0"
target = "erlang"

[dependencies]
gleam_stdlib = ">= 0.44.0 and < 2.0.0"
gleam_erlang = ">= 0.29.0 and < 2.0.0"
gleam_json = ">= 3.0.0 and < 4.0.0"
beryl = { path = "../beryl" }

[dev-dependencies]
gleeunit = ">= 1.0.0 and < 2.0.0"
```

`levee_channels/src/levee_channels.gleam`:
```gleam
//// Levee Channels - Document protocol handlers for beryl
////
//// Provides Fluid Framework protocol support on top of beryl's
//// generic channel infrastructure.

pub const version = "0.1.0"
```

`levee_channels/test/levee_channels_test.gleam`:
```gleam
import gleeunit

pub fn main() {
  gleeunit.main()
}
```

**Step 2: Verify the package compiles**

Run: `cd levee_channels && gleam check`
Expected: Compiles with 0 errors

**Step 3: Commit**

```
feat(levee_channels): create package for levee-specific channel handlers
```

### Task 2: Move document_channel.gleam to levee_channels

**Files:**
- Move: `beryl/src/beryl/levee/document_channel.gleam` → `levee_channels/src/levee_channels/document_channel.gleam`
- Move: `beryl/src/levee_document_ffi.erl` → `levee_channels/src/levee_document_ffi.erl`
- Move: `beryl/src/levee_document_ffi_helpers.erl` → `levee_channels/src/levee_document_ffi_helpers.erl`

**Step 1: Copy files to new location**

```bash
mkdir -p levee_channels/src/levee_channels
cp beryl/src/beryl/levee/document_channel.gleam levee_channels/src/levee_channels/document_channel.gleam
cp beryl/src/levee_document_ffi.erl levee_channels/src/levee_document_ffi.erl
cp beryl/src/levee_document_ffi_helpers.erl levee_channels/src/levee_document_ffi_helpers.erl
```

**Step 2: Update imports in document_channel.gleam**

Change all `beryl/` imports to use the beryl dependency:
```gleam
// These imports stay the same - beryl is now a dependency
import beryl/channel
import beryl/coordinator.{
  type ChannelHandler, type HandleResultErased, type JoinResultErased,
  type SocketContext, ChannelHandler, JoinErrorErased, JoinOkErased,
  NoReplyErased,
}
import beryl/topic
```

The `beryl_ffi` identity function is still in beryl. Document channel uses it for type coercion. Add a local FFI wrapper:

Create `levee_channels/src/levee_channels_ffi.erl`:
```erlang
-module(levee_channels_ffi).
-export([identity/1]).

identity(X) -> X.
```

Update `document_channel.gleam` to use `levee_channels_ffi` instead of `beryl_ffi`:
```gleam
@external(erlang, "levee_channels_ffi", "identity")
fn to_dynamic(value: a) -> Dynamic

@external(erlang, "levee_channels_ffi", "identity")
fn unsafe_coerce_assigns(value: Dynamic) -> DocumentAssigns
```

**Step 3: Verify levee_channels compiles**

Run: `cd levee_channels && gleam check`
Expected: Compiles with 0 errors

**Step 4: Commit**

```
refactor(levee_channels): move document_channel from beryl to levee_channels
```

### Task 3: Move runtime.gleam to levee_channels

**Files:**
- Move: `beryl/src/beryl/levee/runtime.gleam` → `levee_channels/src/levee_channels/runtime.gleam`

**Step 1: Copy and update imports**

```bash
cp beryl/src/beryl/levee/runtime.gleam levee_channels/src/levee_channels/runtime.gleam
```

Update `runtime.gleam`:
```gleam
//// Runtime - Gleam-side bridge for Elixir WebSocket handler
import beryl
import beryl/coordinator
import levee_channels/document_channel
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process

pub fn start() -> Result(beryl.Channels, beryl.StartError) {
  case beryl.start(beryl.default_config()) {
    Error(e) -> Error(e)
    Ok(channels) -> {
      let handler = document_channel.new()
      let _ =
        process.call(channels.coordinator, 5000, fn(reply) {
          coordinator.RegisterChannel("document:*", handler, reply)
        })
      Ok(channels)
    }
  }
}

// ... rest of functions unchanged
```

**Step 2: Verify levee_channels compiles**

Run: `cd levee_channels && gleam check`
Expected: Compiles with 0 errors

**Step 3: Commit**

```
refactor(levee_channels): move runtime.gleam from beryl to levee_channels
```

### Task 4: Remove levee-specific code from beryl

**Files:**
- Delete: `beryl/src/beryl/levee/` directory (document_channel.gleam, runtime.gleam)
- Delete: `beryl/src/levee_document_ffi.erl`
- Delete: `beryl/src/levee_document_ffi_helpers.erl`

**Step 1: Remove files**

```bash
rm -rf beryl/src/beryl/levee/
rm -f beryl/src/levee_document_ffi.erl
rm -f beryl/src/levee_document_ffi_helpers.erl
```

**Step 2: Verify beryl still compiles clean**

Run: `cd beryl && gleam check`
Expected: Compiles with 0 errors, no references to levee

**Step 3: Verify beryl tests pass**

Run: `cd beryl && gleam test`
Expected: All tests pass (topic, wire, socket, config tests)

**Step 4: Commit**

```
refactor(beryl): remove levee-specific code, beryl is now a pure generic library
```

### Task 5: Update Elixir integration to use levee_channels

**Files:**
- Modify: `lib/levee/channels.ex` — Change Gleam module reference
- Modify: `lib/levee_web/socket_handler.ex` — Change Gleam module reference
- Modify: `mix.exs` — Add levee_channels to Gleam build paths
- Modify: `justfile` — Update build commands if needed

**Step 1: Update Levee.Channels GenServer**

In `lib/levee/channels.ex`, change the Gleam module atom:
```elixir
# Old: :beryl@levee@runtime
# New: :levee_channels@runtime
@compile {:no_warn_undefined, [:levee_channels@runtime]}

def init(_opts) do
  case :levee_channels@runtime.start() do
    # ...
  end
end
```

**Step 2: Update SocketHandler**

In `lib/levee_web/socket_handler.ex`:
```elixir
# Old: :beryl@levee@runtime
# New: :levee_channels@runtime
@compile {:no_warn_undefined, [:levee_channels@runtime]}

def init(state) do
  # ...
  :levee_channels@runtime.notify_connected(channels, socket_id, send_fn, me)
  # ...
end

def handle_in({text, [opcode: :text]}, state) do
  :levee_channels@runtime.handle_raw_message(state.channels, state.socket_id, text)
  {:ok, state}
end

def terminate(_reason, %{channels: channels, socket_id: socket_id}) do
  :levee_channels@runtime.notify_disconnected(channels, socket_id)
  :ok
end
```

**Step 3: Update mix.exs build paths**

Add `levee_channels` to the Gleam build pipeline. Check `mix.exs` and `justfile` for where Gleam packages are built and ensure `levee_channels` is included alongside `beryl`, `levee_protocol`, and `levee_auth`.

**Step 4: Full test run**

Run: `just build && just test`
Expected: All 138 tests pass

**Step 5: Commit**

```
refactor: update Elixir integration to use levee_channels package
```

### Task 6: Verify clean separation with grep

**Step 1: Verify beryl has no levee references**

Run: `rg -i "levee|document|fluid|jwt|session" beryl/src/ --type gleam`
Expected: No matches (beryl is levee-free)

Run: `rg -i "levee|document" beryl/src/ --type erlang`
Expected: No matches

**Step 2: Verify levee_channels has all needed levee code**

Run: `rg "document_channel|levee_document_ffi" levee_channels/src/`
Expected: Matches in document_channel.gleam and ffi files

**Step 3: Commit if any cleanup needed, otherwise move on**

---

## Phase 2: PubSub via Erlang pg

PubSub needs to come before Presence because Presence uses PubSub for CRDT gossip.

### Task 7: Create beryl/pubsub.gleam

**Files:**
- Create: `beryl/src/beryl/pubsub.gleam`
- Create: `beryl/src/beryl/pubsub_ffi.erl`

**Step 1: Write the Erlang FFI for pg module**

`beryl/src/beryl/pubsub_ffi.erl`:
```erlang
-module(beryl_pubsub_ffi).
-export([
    start_pg_scope/1,
    join_group/3,
    leave_group/3,
    get_members/2,
    get_local_members/2
]).

%% Start a pg scope (call once at startup)
start_pg_scope(Scope) ->
    pg:start(Scope).

%% Join a process to a group (topic)
join_group(Scope, Group, Pid) ->
    pg:join(Scope, Group, Pid).

%% Leave a group
leave_group(Scope, Group, Pid) ->
    pg:leave(Scope, Group, Pid).

%% Get all members of a group (across all nodes)
get_members(Scope, Group) ->
    pg:get_members(Scope, Group).

%% Get local members of a group (this node only)
get_local_members(Scope, Group) ->
    pg:get_local_members(Scope, Group).
```

**Step 2: Write the Gleam pubsub module**

`beryl/src/beryl/pubsub.gleam`:
```gleam
//// PubSub - Distributed publish/subscribe via Erlang pg
////
//// Provides distributed message delivery across BEAM nodes using
//// OTP's built-in process groups. Each topic maps to a pg group,
//// allowing broadcasts to reach all subscribers on all connected nodes.
////
//// ## Example
////
//// ```gleam
//// let assert Ok(ps) = pubsub.start(pubsub.default_config())
//// pubsub.subscribe(ps, "room:lobby")
//// pubsub.broadcast(ps, "room:lobby", "new_msg", json.string("hello"))
//// ```

import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Pid}
import gleam/json
import gleam/list

/// PubSub configuration
pub type Config {
  Config(
    /// Name for the pg scope (allows multiple independent pubsub systems)
    scope: Dynamic,
  )
}

/// PubSub handle
pub type PubSub {
  PubSub(scope: Dynamic)
}

/// Errors when starting PubSub
pub type StartError {
  PgStartFailed
}

/// Message delivered to subscribers
pub type Broadcast {
  Broadcast(topic: String, event: String, payload: json.Json)
}

// FFI declarations
@external(erlang, "beryl_pubsub_ffi", "start_pg_scope")
fn pg_start(scope: Dynamic) -> Dynamic

@external(erlang, "beryl_pubsub_ffi", "join_group")
fn pg_join(scope: Dynamic, group: String, pid: Pid) -> Dynamic

@external(erlang, "beryl_pubsub_ffi", "leave_group")
fn pg_leave(scope: Dynamic, group: String, pid: Pid) -> Dynamic

@external(erlang, "beryl_pubsub_ffi", "get_members")
fn pg_get_members(scope: Dynamic, group: String) -> List(Pid)

@external(erlang, "beryl_pubsub_ffi", "get_local_members")
fn pg_get_local_members(scope: Dynamic, group: String) -> List(Pid)

/// Erlang atom creation for scope name
@external(erlang, "erlang", "binary_to_atom")
fn binary_to_atom(name: String) -> Dynamic

/// Default configuration
pub fn default_config() -> Config {
  Config(scope: binary_to_atom("beryl_pubsub"))
}

/// Create a config with a custom scope name
pub fn config_with_scope(name: String) -> Config {
  Config(scope: binary_to_atom(name))
}

/// Start the PubSub system
///
/// Initializes an Erlang pg scope. Call once at application startup.
pub fn start(config: Config) -> Result(PubSub, StartError) {
  let _ = pg_start(config.scope)
  Ok(PubSub(scope: config.scope))
}

/// Subscribe the current process to a topic
///
/// The calling process will receive `Broadcast` messages when
/// messages are published to this topic.
pub fn subscribe(pubsub: PubSub, topic: String) -> Nil {
  pg_join(pubsub.scope, topic, process.self())
  Nil
}

/// Unsubscribe the current process from a topic
pub fn unsubscribe(pubsub: PubSub, topic: String) -> Nil {
  pg_leave(pubsub.scope, topic, process.self())
  Nil
}

/// Broadcast a message to all subscribers of a topic (all nodes)
pub fn broadcast(
  pubsub: PubSub,
  topic: String,
  event: String,
  payload: json.Json,
) -> Nil {
  let msg = Broadcast(topic: topic, event: event, payload: payload)
  let members = pg_get_members(pubsub.scope, topic)
  list.each(members, fn(pid) { process.send_pid(pid, msg) })
}

/// Broadcast to all subscribers except one process
pub fn broadcast_from(
  pubsub: PubSub,
  from: Pid,
  topic: String,
  event: String,
  payload: json.Json,
) -> Nil {
  let msg = Broadcast(topic: topic, event: event, payload: payload)
  let members = pg_get_members(pubsub.scope, topic)
  list.each(members, fn(pid) {
    case pid == from {
      True -> Nil
      False -> process.send_pid(pid, msg)
    }
  })
}

/// Broadcast only to subscribers on the local node
pub fn local_broadcast(
  pubsub: PubSub,
  topic: String,
  event: String,
  payload: json.Json,
) -> Nil {
  let msg = Broadcast(topic: topic, event: event, payload: payload)
  let members = pg_get_local_members(pubsub.scope, topic)
  list.each(members, fn(pid) { process.send_pid(pid, msg) })
}

/// Get all subscriber PIDs for a topic (across all nodes)
pub fn subscribers(pubsub: PubSub, topic: String) -> List(Pid) {
  pg_get_members(pubsub.scope, topic)
}

/// Get subscriber count for a topic
pub fn subscriber_count(pubsub: PubSub, topic: String) -> Int {
  list.length(pg_get_members(pubsub.scope, topic))
}
```

**Step 3: Add a send_pid helper if needed**

Check if `gleam/erlang/process` has `send_pid`. If not, add FFI:

`beryl/src/beryl/pubsub_ffi.erl` (add):
```erlang
-export([send_to_pid/2]).

send_to_pid(Pid, Msg) ->
    Pid ! Msg,
    nil.
```

And in pubsub.gleam, use this if `process.send_pid` doesn't exist:
```gleam
@external(erlang, "beryl_pubsub_ffi", "send_to_pid")
fn send_to_pid(pid: Pid, msg: a) -> Nil
```

**Step 4: Verify it compiles**

Run: `cd beryl && gleam check`
Expected: Compiles with 0 errors

**Step 5: Commit**

```
feat(beryl): add PubSub module using Erlang pg for distributed messaging
```

### Task 8: Write PubSub tests

**Files:**
- Modify: `beryl/test/beryl_test.gleam` — Add pubsub tests

**Step 1: Write failing tests**

Add to `beryl/test/beryl_test.gleam`:
```gleam
import beryl/pubsub

// PubSub tests

pub fn pubsub_start_test() {
  let assert Ok(_ps) = pubsub.start(pubsub.default_config())
}

pub fn pubsub_subscribe_and_count_test() {
  let assert Ok(ps) = pubsub.start(pubsub.config_with_scope("test_sub"))
  pubsub.subscribe(ps, "test:topic")
  pubsub.subscriber_count(ps, "test:topic")
  |> should.equal(1)
}

pub fn pubsub_unsubscribe_test() {
  let assert Ok(ps) = pubsub.start(pubsub.config_with_scope("test_unsub"))
  pubsub.subscribe(ps, "test:unsub")
  pubsub.subscriber_count(ps, "test:unsub") |> should.equal(1)
  pubsub.unsubscribe(ps, "test:unsub")
  pubsub.subscriber_count(ps, "test:unsub") |> should.equal(0)
}
```

**Step 2: Run tests**

Run: `cd beryl && gleam test`
Expected: All tests pass (new + existing)

**Step 3: Commit**

```
test(beryl): add PubSub unit tests
```

### Task 9: Integrate PubSub with coordinator

**Files:**
- Modify: `beryl/src/beryl.gleam` — Add optional PubSub to Channels
- Modify: `beryl/src/beryl/coordinator.gleam` — Subscribe/unsubscribe topics via PubSub

**Step 1: Add PubSub to Config and Channels**

In `beryl/src/beryl.gleam`, update types:
```gleam
import beryl/pubsub.{type PubSub}
import gleam/option.{type Option, None, Some}

pub type Config {
  Config(
    heartbeat_interval_ms: Int,
    heartbeat_timeout_ms: Int,
    max_connections_per_ip: Int,
    /// Optional PubSub for distributed broadcasts
    pubsub: Option(PubSub),
  )
}

pub fn default_config() -> Config {
  Config(
    heartbeat_interval_ms: 30_000,
    heartbeat_timeout_ms: 60_000,
    max_connections_per_ip: 0,
    pubsub: None,
  )
}

pub fn with_pubsub(config: Config, pubsub: PubSub) -> Config {
  Config(..config, pubsub: Some(pubsub))
}

pub type Channels {
  Channels(
    coordinator: Subject(coordinator.Message),
    config: Config,
    pubsub: Option(PubSub),
  )
}
```

Update `start()`:
```gleam
pub fn start(config: Config) -> Result(Channels, StartError) {
  case coordinator.start() {
    Error(_) -> Error(CoordinatorStartFailed)
    Ok(coord) -> Ok(Channels(coordinator: coord, config: config, pubsub: config.pubsub))
  }
}
```

Update `broadcast()` to use PubSub when available:
```gleam
pub fn broadcast(
  channels: Channels,
  topic_name: String,
  event: String,
  payload: json.Json,
) -> Nil {
  // Always send to local coordinator
  process.send(
    channels.coordinator,
    coordinator.Broadcast(topic_name, event, payload, None),
  )
  // If PubSub enabled, also broadcast to other nodes
  case channels.pubsub {
    Some(ps) -> pubsub.broadcast(ps, topic_name, event, payload)
    None -> Nil
  }
}
```

**Step 2: Verify it compiles and tests pass**

Run: `cd beryl && gleam test`
Expected: All tests pass

**Step 3: Commit**

```
feat(beryl): integrate PubSub with coordinator for distributed broadcasts
```

---

## Phase 3: Presence (CRDT-based)

### Task 10: Create beryl/presence.gleam with types

**Files:**
- Create: `beryl/src/beryl/presence.gleam`
- Create: `beryl/src/beryl/presence_ffi.erl`

**Step 1: Define core types and API**

`beryl/src/beryl/presence.gleam`:
```gleam
//// Presence - CRDT-based distributed presence tracking
////
//// Tracks which users/entities are present on each topic using a
//// state-based CRDT (inspired by Phoenix.Presence). Each node tracks
//// its own presences authoritatively and replicates state via PubSub.
////
//// Presences are identified by a key (e.g., user ID) and carry
//// arbitrary metadata. Multiple presences can exist for the same key
//// (e.g., a user with multiple tabs open).
////
//// ## Example
////
//// ```gleam
//// let assert Ok(presence) = presence.start(presence.default_config(pubsub))
//// presence.track(presence, "room:lobby", "user:alice", json.object([
////   #("status", json.string("online")),
//// ]))
//// let users = presence.list(presence, "room:lobby")
//// ```

import beryl/pubsub.{type PubSub}
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Subject}
import gleam/json
import gleam/option.{type Option}

/// Configuration for the presence system
pub type Config {
  Config(
    /// PubSub for cross-node replication
    pubsub: PubSub,
    /// How often to broadcast full state for consistency (ms, default: 30000)
    sync_interval_ms: Int,
  )
}

/// Presence system handle
pub type Presence {
  Presence(actor: Subject(PresenceMessage))
}

/// Errors when starting presence
pub type PresenceStartError {
  PresenceActorStartFailed
}

/// A single presence entry (one "connection" of a key)
pub type PresenceMeta {
  PresenceMeta(
    /// Unique reference for this specific presence instance
    ref: String,
    /// Arbitrary metadata (status, device info, etc.)
    meta: json.Json,
    /// Node that owns this presence
    node: Dynamic,
  )
}

/// All presences for a single key
pub type PresenceEntry {
  PresenceEntry(key: String, metas: List(PresenceMeta))
}

/// Diff between two presence states
pub type PresenceDiff {
  PresenceDiff(joins: List(PresenceEntry), leaves: List(PresenceEntry))
}

/// Internal actor messages
pub type PresenceMessage {
  Track(topic: String, key: String, meta: json.Json, reply: Subject(Result(String, Nil)))
  Untrack(topic: String, key: String, ref: Option(String))
  List(topic: String, reply: Subject(List(PresenceEntry)))
  GetByKey(topic: String, key: String, reply: Subject(Option(PresenceEntry)))
  // Cross-node replication
  RemoteState(node: Dynamic, topic: String, state: Dict(String, List(PresenceMeta)))
  NodeDown(node: Dynamic)
}

/// Default configuration
pub fn default_config(pubsub: PubSub) -> Config {
  Config(pubsub: pubsub, sync_interval_ms: 30_000)
}

/// Start the presence tracking system
pub fn start(config: Config) -> Result(Presence, PresenceStartError) {
  // Implementation in Task 11
  todo as "presence.start"
}

/// Track a presence on a topic
///
/// Returns a unique ref for this presence instance that can be used
/// to untrack a specific presence (e.g., when one of multiple tabs closes).
pub fn track(
  presence: Presence,
  topic: String,
  key: String,
  meta: json.Json,
) -> Result(String, Nil) {
  process.call(presence.actor, 5000, fn(reply) {
    Track(topic, key, meta, reply)
  })
}

/// Untrack a presence
///
/// If ref is None, removes all presences for the key on this topic.
/// If ref is Some(ref), removes only the specific presence instance.
pub fn untrack(
  presence: Presence,
  topic: String,
  key: String,
  ref: Option(String),
) -> Nil {
  process.send(presence.actor, Untrack(topic, key, ref))
}

/// List all presences on a topic
pub fn list(
  presence: Presence,
  topic: String,
) -> List(PresenceEntry) {
  process.call(presence.actor, 5000, fn(reply) {
    List(topic, reply)
  })
}

/// Get presences for a specific key on a topic
pub fn get_by_key(
  presence: Presence,
  topic: String,
  key: String,
) -> Option(PresenceEntry) {
  process.call(presence.actor, 5000, fn(reply) {
    GetByKey(topic, key, reply)
  })
}
```

**Step 2: Verify it compiles (with todo stubs)**

Run: `cd beryl && gleam check`
Expected: Compiles (todo is valid Gleam)

**Step 3: Commit**

```
feat(beryl): add presence module types and API surface
```

### Task 11: Implement presence actor with CRDT state

**Files:**
- Modify: `beryl/src/beryl/presence.gleam` — Implement the actor

**Step 1: Implement start() and actor loop**

Replace the `todo` in `start()` with a real actor implementation. The CRDT approach:

- Each node maintains a `Dict(node, Dict(topic, Dict(key, List(PresenceMeta))))` — the "clock" is node-specific; each node is authoritative over its own entries
- On track/untrack: update local state, compute diff, broadcast diff to PubSub
- On remote state: merge by replacing that node's entries entirely (last-write-wins per node)
- On node down: remove all entries for that node, broadcast diff

Key implementation details:
- Use `process.send_after` for periodic sync interval
- Generate unique refs via `crypto.strong_random_bytes`
- Push `"presence_state"` and `"presence_diff"` events to channel subscribers

**Step 2: Write the implementation**

This is the most complex task. The actor state:
```gleam
type State {
  State(
    /// node -> topic -> key -> List(PresenceMeta)
    presences: Dict(Dynamic, Dict(String, Dict(String, List(PresenceMeta)))),
    /// Our node identity
    local_node: Dynamic,
    /// PubSub for replication
    pubsub: PubSub,
  )
}
```

Core CRDT operations:
- `merge_state(local, remote_node, remote_state)` — Replace remote node's entries
- `compute_diff(old_state, new_state)` — Determine joins/leaves
- `flatten_for_topic(state, topic)` — Aggregate all nodes' entries for a topic

**Step 3: Run tests (from Task 12)**

**Step 4: Commit**

```
feat(beryl): implement CRDT-based presence actor
```

### Task 12: Write presence tests

**Files:**
- Modify: `beryl/test/beryl_test.gleam` — Add presence tests

**Step 1: Write tests**

```gleam
import beryl/presence
import beryl/pubsub

// Presence tests

pub fn presence_track_and_list_test() {
  let assert Ok(ps) = pubsub.start(pubsub.config_with_scope("test_pres"))
  let assert Ok(pres) = presence.start(presence.default_config(ps))

  let assert Ok(_ref) = presence.track(pres, "room:lobby", "user:alice", json.object([
    #("status", json.string("online")),
  ]))

  let entries = presence.list(pres, "room:lobby")
  list.length(entries) |> should.equal(1)
}

pub fn presence_untrack_test() {
  let assert Ok(ps) = pubsub.start(pubsub.config_with_scope("test_pres_ut"))
  let assert Ok(pres) = presence.start(presence.default_config(ps))

  let assert Ok(ref) = presence.track(pres, "room:lobby", "user:bob", json.object([]))
  presence.untrack(pres, "room:lobby", "user:bob", option.Some(ref))

  // Give actor time to process
  process.sleep(50)

  let entries = presence.list(pres, "room:lobby")
  list.length(entries) |> should.equal(0)
}

pub fn presence_multiple_metas_test() {
  let assert Ok(ps) = pubsub.start(pubsub.config_with_scope("test_pres_mm"))
  let assert Ok(pres) = presence.start(presence.default_config(ps))

  // Same user, two "tabs"
  let assert Ok(_) = presence.track(pres, "room:lobby", "user:alice", json.object([
    #("device", json.string("desktop")),
  ]))
  let assert Ok(_) = presence.track(pres, "room:lobby", "user:alice", json.object([
    #("device", json.string("mobile")),
  ]))

  let entries = presence.list(pres, "room:lobby")
  list.length(entries) |> should.equal(1)  // One key
  let assert [entry] = entries
  list.length(entry.metas) |> should.equal(2)  // Two metas
}

pub fn presence_get_by_key_test() {
  let assert Ok(ps) = pubsub.start(pubsub.config_with_scope("test_pres_gbk"))
  let assert Ok(pres) = presence.start(presence.default_config(ps))

  let assert Ok(_) = presence.track(pres, "room:lobby", "user:alice", json.object([]))

  let result = presence.get_by_key(pres, "room:lobby", "user:alice")
  result |> should.be_some

  let result = presence.get_by_key(pres, "room:lobby", "user:missing")
  result |> should.equal(option.None)
}

pub fn presence_empty_topic_test() {
  let assert Ok(ps) = pubsub.start(pubsub.config_with_scope("test_pres_empty"))
  let assert Ok(pres) = presence.start(presence.default_config(ps))

  let entries = presence.list(pres, "room:empty")
  list.length(entries) |> should.equal(0)
}
```

**Step 2: Run tests**

Run: `cd beryl && gleam test`
Expected: All tests pass

**Step 3: Commit**

```
test(beryl): add presence tracking tests
```

---

## Phase 4: Channel Groups

### Task 13: Create beryl/group.gleam

**Files:**
- Create: `beryl/src/beryl/group.gleam`

**Step 1: Write the group module**

`beryl/src/beryl/group.gleam`:
```gleam
//// Channel Groups - Aggregate multiple topics
////
//// Groups allow broadcasting to multiple related topics at once.
//// Useful for organizational hierarchies, user notification channels, etc.
////
//// ## Example
////
//// ```gleam
//// let assert Ok(groups) = group.start()
//// group.add(groups, "org:acme", "room:lobby")
//// group.add(groups, "org:acme", "room:engineering")
//// group.broadcast(groups, channels, "org:acme", "announcement", payload)
//// ```

import beryl
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/set.{type Set}

/// Group registry handle
pub type Groups {
  Groups(actor: Subject(GroupMessage))
}

/// Errors when starting groups
pub type GroupStartError {
  GroupActorStartFailed
}

/// Internal messages
pub type GroupMessage {
  Create(name: String, reply: Subject(Result(Nil, GroupError)))
  Delete(name: String)
  Add(group_name: String, topic: String, reply: Subject(Result(Nil, GroupError)))
  Remove(group_name: String, topic: String)
  GetTopics(group_name: String, reply: Subject(Option(Set(String))))
  ListGroups(reply: Subject(List(String)))
  BroadcastGroup(
    group_name: String,
    channels: beryl.Channels,
    event: String,
    payload: json.Json,
  )
}

/// Group errors
pub type GroupError {
  GroupNotFound(String)
  GroupAlreadyExists(String)
}

/// Internal state
type State {
  State(groups: Dict(String, Set(String)))
}

/// Start the group registry
pub fn start() -> Result(Groups, GroupStartError) {
  let initial = State(groups: dict.new())
  case
    actor.new(initial)
    |> actor.on_message(handle_message)
    |> actor.start
  {
    Error(_) -> Error(GroupActorStartFailed)
    Ok(started) -> Ok(Groups(actor: started.data))
  }
}

/// Create a new group
pub fn create(groups: Groups, name: String) -> Result(Nil, GroupError) {
  process.call(groups.actor, 5000, fn(reply) { Create(name, reply) })
}

/// Delete a group
pub fn delete(groups: Groups, name: String) -> Nil {
  process.send(groups.actor, Delete(name))
}

/// Add a topic to a group
pub fn add(
  groups: Groups,
  group_name: String,
  topic: String,
) -> Result(Nil, GroupError) {
  process.call(groups.actor, 5000, fn(reply) { Add(group_name, topic, reply) })
}

/// Remove a topic from a group
pub fn remove(groups: Groups, group_name: String, topic: String) -> Nil {
  process.send(groups.actor, Remove(group_name, topic))
}

/// Get all topics in a group
pub fn topics(groups: Groups, group_name: String) -> Option(Set(String)) {
  process.call(groups.actor, 5000, fn(reply) { GetTopics(group_name, reply) })
}

/// List all group names
pub fn list_groups(groups: Groups) -> List(String) {
  process.call(groups.actor, 5000, fn(reply) { ListGroups(reply) })
}

/// Broadcast to all topics in a group
pub fn broadcast(
  groups: Groups,
  channels: beryl.Channels,
  group_name: String,
  event: String,
  payload: json.Json,
) -> Nil {
  process.send(
    groups.actor,
    BroadcastGroup(group_name, channels, event, payload),
  )
}

// Actor message handler
fn handle_message(
  state: State,
  message: GroupMessage,
) -> actor.Next(State, GroupMessage) {
  case message {
    Create(name, reply) -> {
      case dict.has_key(state.groups, name) {
        True -> {
          process.send(reply, Error(GroupAlreadyExists(name)))
          actor.continue(state)
        }
        False -> {
          let new_groups = dict.insert(state.groups, name, set.new())
          process.send(reply, Ok(Nil))
          actor.continue(State(groups: new_groups))
        }
      }
    }

    Delete(name) -> {
      let new_groups = dict.delete(state.groups, name)
      actor.continue(State(groups: new_groups))
    }

    Add(group_name, topic, reply) -> {
      case dict.get(state.groups, group_name) {
        Error(_) -> {
          process.send(reply, Error(GroupNotFound(group_name)))
          actor.continue(state)
        }
        Ok(topics) -> {
          let new_topics = set.insert(topics, topic)
          let new_groups = dict.insert(state.groups, group_name, new_topics)
          process.send(reply, Ok(Nil))
          actor.continue(State(groups: new_groups))
        }
      }
    }

    Remove(group_name, topic) -> {
      case dict.get(state.groups, group_name) {
        Error(_) -> actor.continue(state)
        Ok(topics) -> {
          let new_topics = set.delete(topics, topic)
          let new_groups = dict.insert(state.groups, group_name, new_topics)
          actor.continue(State(groups: new_groups))
        }
      }
    }

    GetTopics(group_name, reply) -> {
      case dict.get(state.groups, group_name) {
        Error(_) -> {
          process.send(reply, None)
          actor.continue(state)
        }
        Ok(topics) -> {
          process.send(reply, Some(topics))
          actor.continue(state)
        }
      }
    }

    ListGroups(reply) -> {
      process.send(reply, dict.keys(state.groups))
      actor.continue(state)
    }

    BroadcastGroup(group_name, channels, event, payload) -> {
      case dict.get(state.groups, group_name) {
        Error(_) -> actor.continue(state)
        Ok(topics) -> {
          set.to_list(topics)
          |> list.each(fn(topic) {
            beryl.broadcast(channels, topic, event, payload)
          })
          actor.continue(state)
        }
      }
    }
  }
}
```

**Step 2: Verify it compiles**

Run: `cd beryl && gleam check`
Expected: Compiles with 0 errors

**Step 3: Commit**

```
feat(beryl): add channel groups for multi-topic broadcasting
```

### Task 14: Write group tests

**Files:**
- Modify: `beryl/test/beryl_test.gleam` — Add group tests

**Step 1: Write tests**

```gleam
import beryl/group

// Group tests

pub fn group_create_and_list_test() {
  let assert Ok(groups) = group.start()
  let assert Ok(Nil) = group.create(groups, "org:acme")

  group.list_groups(groups)
  |> list.length
  |> should.equal(1)
}

pub fn group_add_topics_test() {
  let assert Ok(groups) = group.start()
  let assert Ok(Nil) = group.create(groups, "org:acme")
  let assert Ok(Nil) = group.add(groups, "org:acme", "room:lobby")
  let assert Ok(Nil) = group.add(groups, "org:acme", "room:eng")

  let assert option.Some(topics) = group.topics(groups, "org:acme")
  set.size(topics) |> should.equal(2)
  set.contains(topics, "room:lobby") |> should.be_true
  set.contains(topics, "room:eng") |> should.be_true
}

pub fn group_remove_topic_test() {
  let assert Ok(groups) = group.start()
  let assert Ok(Nil) = group.create(groups, "org:acme")
  let assert Ok(Nil) = group.add(groups, "org:acme", "room:lobby")
  let assert Ok(Nil) = group.add(groups, "org:acme", "room:eng")

  group.remove(groups, "org:acme", "room:lobby")

  let assert option.Some(topics) = group.topics(groups, "org:acme")
  set.size(topics) |> should.equal(1)
  set.contains(topics, "room:eng") |> should.be_true
}

pub fn group_not_found_test() {
  let assert Ok(groups) = group.start()
  let assert Error(group.GroupNotFound(_)) = group.add(groups, "missing", "room:1")
}

pub fn group_already_exists_test() {
  let assert Ok(groups) = group.start()
  let assert Ok(Nil) = group.create(groups, "org:acme")
  let assert Error(group.GroupAlreadyExists(_)) = group.create(groups, "org:acme")
}

pub fn group_delete_test() {
  let assert Ok(groups) = group.start()
  let assert Ok(Nil) = group.create(groups, "org:temp")
  group.delete(groups, "org:temp")
  group.topics(groups, "org:temp") |> should.equal(option.None)
}

pub fn group_topics_nonexistent_test() {
  let assert Ok(groups) = group.start()
  group.topics(groups, "nope") |> should.equal(option.None)
}
```

**Step 2: Run tests**

Run: `cd beryl && gleam test`
Expected: All tests pass

**Step 3: Commit**

```
test(beryl): add channel group tests
```

---

## Phase 5: Integration & Documentation

### Task 15: Update beryl.gleam public API to re-export new modules

**Files:**
- Modify: `beryl/src/beryl.gleam` — Add convenience re-exports and docs

**Step 1: Update module doc and add re-exports**

Update the module-level documentation in `beryl.gleam` to mention all features:

```gleam
//// Beryl - Type-safe real-time communication for Gleam
////
//// A library for building real-time applications with:
//// - **Channels** - Topic-based message handlers with typed assigns
//// - **Presence** - CRDT-based distributed presence tracking
//// - **PubSub** - Distributed messaging via Erlang pg
//// - **Groups** - Multi-topic broadcasting
//// - **Transport** - WebSocket transport (Wisp integration)
////
//// ## Quick Start
////
//// ```gleam
//// import beryl
//// import beryl/channel
//// import beryl/pubsub
//// import beryl/presence
////
//// pub fn main() {
////   // Start PubSub for distributed messaging
////   let assert Ok(ps) = pubsub.start(pubsub.default_config())
////
////   // Start channels with PubSub
////   let config = beryl.default_config() |> beryl.with_pubsub(ps)
////   let assert Ok(channels) = beryl.start(config)
////
////   // Start presence tracking
////   let assert Ok(pres) = presence.start(presence.default_config(ps))
////
////   // Register a channel handler
////   let _ = beryl.register(channels, "room:*", room_channel.new())
//// }
//// ```
```

**Step 2: Verify everything compiles and tests pass**

Run: `cd beryl && gleam test`
Expected: All tests pass

**Step 3: Commit**

```
docs(beryl): update module documentation with full feature set
```

### Task 16: Full integration test

**Files:**
- No new files — just verify the full build

**Step 1: Build everything**

Run: `just build`
Expected: All Gleam packages (beryl, levee_protocol, levee_auth, levee_channels) compile

**Step 2: Run all tests**

Run: `just test`
Expected: All Elixir + Gleam tests pass (138+ tests)

**Step 3: Run beryl tests specifically**

Run: `cd beryl && gleam test`
Expected: All beryl tests pass (topic, wire, socket, config, pubsub, presence, group)

**Step 4: Final commit if any fixups needed**

---

## Summary

| Task | Description | Phase |
|------|-------------|-------|
| 1-6 | Extract levee-specific code into `levee_channels` package | Phase 1: Extraction |
| 7-9 | PubSub module using Erlang pg, integrated with coordinator | Phase 2: PubSub |
| 10-12 | CRDT-based Presence tracking with tests | Phase 3: Presence |
| 13-14 | Channel Groups for multi-topic broadcasting | Phase 4: Groups |
| 15-16 | Documentation update and full integration test | Phase 5: Integration |

**Estimated total: 16 tasks**

Rate limiting is deferred to a separate effort using the library extracted from birch.
