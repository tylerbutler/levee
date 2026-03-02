# Beryl Standalone Channels Library Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Extract beryl into a standalone, generic Gleam channels library with Presence (CRDT), PubSub (pg), and Channel Groups — removing all levee-specific code from beryl itself.

**Architecture:** Beryl is currently ~90% generic channels infrastructure and ~10% levee-specific document protocol. We'll move levee-specific code into levee proper (new `levee_channels` Gleam package), then add Presence, PubSub, and Groups as new beryl modules. We start with the CRDT as a pure, well-tested data structure before wrapping it in an actor.

**Tech Stack:** Gleam (targeting Erlang/BEAM), OTP actors, Erlang `pg` module for distributed PubSub, CRDT-based presence tracking

**Reference:** The CRDT design is based on [Phoenix.Tracker.State](https://github.com/phoenixframework/phoenix_pubsub/blob/main/lib/phoenix/tracker/state.ex) — a causal-context CRDT with delta tracking. See also the [DockYard blog post](https://dockyard.com/blog/2016/03/25/what-makes-phoenix-presence-special-sneak-peek) on what makes Phoenix Presence special.

---

## Phase 0: Pure CRDT Data Structure

Build the core CRDT as a pure module with no actors, no IO, no side effects — just data in, data out. This is the hard part and must be rock-solid before we wrap it in anything.

### Background: How the CRDT Works

The presence CRDT is a **causal-context add-wins set**:

- **Replicas**: Each node has a unique name and a monotonic clock
- **Context**: `Dict(replica, clock)` — a vector clock tracking the latest known state per replica
- **Clouds**: `Dict(replica, Set(clock))` — tags seen but not yet compacted into context (handles out-of-order delivery)
- **Values**: `Dict(tag, Entry)` where `tag = #(replica, clock)` — the actual tracked presences
- **Entries**: `#(topic, key, pid_or_id, meta)` — what's being tracked

**Key operations:**
- `join` — add an entry, increment local clock, tag it
- `leave` — remove an entry by tag
- `merge` — combine remote state with local: accept new tags, observe removals, advance context
- `compact` — compress clouds into context when they form contiguous sequences
- `extract` — produce a minimal state (delta) for sending to a specific remote replica

**Conflict resolution:** Add-wins via causal context. If a tag is "in" the remote's causal context but absent from their values, the remote has observed and removed it. If a tag is NOT in the remote's context, the remote hasn't seen it yet, so we keep it.

### Task 1: Create beryl/presence/state.gleam with core types

**Files:**
- Create: `beryl/src/beryl/presence/state.gleam`

**Step 1: Define the types**

```gleam
//// Presence State - Pure CRDT for distributed presence tracking
////
//// A causal-context add-wins observed-remove set, inspired by Phoenix.Tracker.State.
//// This module is a pure data structure with no actors or side effects.
////
//// Each node (replica) tracks its own presences authoritatively. State is
//// replicated by extracting deltas and merging them at remote replicas.
//// Conflicts are resolved causally: adds win over concurrent removes.

import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/json
import gleam/option.{type Option}
import gleam/set.{type Set}

/// Unique identifier for a node in the cluster
pub type Replica =
  String

/// Monotonically increasing counter per replica
pub type Clock =
  Int

/// A tag uniquely identifies when and where an entry was created
pub type Tag {
  Tag(replica: Replica, clock: Clock)
}

/// A tracked presence entry
pub type Entry {
  Entry(
    topic: String,
    key: String,
    /// Unique identifier for the tracked entity (e.g., socket ID, user ID)
    pid: String,
    /// Arbitrary metadata
    meta: json.Json,
  )
}

/// Replica status
pub type ReplicaStatus {
  Up
  Down
}

/// The CRDT state
pub type State {
  State(
    /// This node's replica name
    replica: Replica,
    /// Vector clock: replica -> latest compacted clock value
    context: Dict(Replica, Clock),
    /// Per-replica sets of observed-but-not-compacted clock values
    clouds: Dict(Replica, Set(Clock)),
    /// Tag -> Entry: all tracked presences
    values: Dict(Tag, Entry),
    /// Replica status tracking
    replicas: Dict(Replica, ReplicaStatus),
  )
}

/// A diff representing changes between two states
pub type Diff {
  Diff(
    joins: Dict(String, List(#(String, String, json.Json))),
    leaves: Dict(String, List(#(String, String, json.Json))),
  )
}
```

**Step 2: Verify it compiles**

Run: `cd beryl && gleam check`
Expected: Compiles with 0 errors

**Step 3: Commit**

```
feat(beryl): add presence CRDT core types
```

### Task 2: Implement new, join, and leave

**Files:**
- Modify: `beryl/src/beryl/presence/state.gleam`

**Step 1: Write failing tests**

Create `beryl/test/presence_state_test.gleam`:
```gleam
import beryl/presence/state.{type State, Tag, Entry}
import gleam/dict
import gleam/json
import gleam/list
import gleam/option
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

// ── new ──────────────────────────────────────────────────────────────

pub fn new_creates_empty_state_test() {
  let s = state.new("node1")
  state.online_list(s) |> should.equal([])
  s.replica |> should.equal("node1")
}

// ── join ─────────────────────────────────────────────────────────────

pub fn join_makes_user_online_test() {
  let s = state.new("node1")
  let s = state.join(s, "pid1", "room:lobby", "user:alice", json.object([
    #("status", json.string("online")),
  ]))

  let entries = state.get_by_topic(s, "room:lobby")
  list.length(entries) |> should.equal(1)
  let assert [#(_pid, "user:alice", _meta)] = entries
}

pub fn join_increments_clock_test() {
  let s = state.new("node1")
  let s = state.join(s, "pid1", "room:lobby", "alice", json.object([]))
  let s = state.join(s, "pid2", "room:lobby", "bob", json.object([]))

  let entries = state.get_by_topic(s, "room:lobby")
  list.length(entries) |> should.equal(2)
}

pub fn join_multiple_topics_test() {
  let s = state.new("node1")
  let s = state.join(s, "pid1", "room:lobby", "alice", json.object([]))
  let s = state.join(s, "pid1", "room:private", "alice", json.object([]))

  state.get_by_topic(s, "room:lobby") |> list.length |> should.equal(1)
  state.get_by_topic(s, "room:private") |> list.length |> should.equal(1)
}

// ── leave ────────────────────────────────────────────────────────────

pub fn leave_removes_user_test() {
  let s = state.new("node1")
  let s = state.join(s, "pid1", "room:lobby", "alice", json.object([]))
  let s = state.leave(s, "pid1", "room:lobby", "alice")

  state.get_by_topic(s, "room:lobby") |> should.equal([])
}

pub fn leave_nonexistent_is_noop_test() {
  let s = state.new("node1")
  let s = state.leave(s, "pid1", "room:lobby", "alice")
  state.online_list(s) |> should.equal([])
}

pub fn leave_all_by_pid_test() {
  let s = state.new("node1")
  let s = state.join(s, "pid1", "room:lobby", "alice", json.object([]))
  let s = state.join(s, "pid1", "room:private", "alice", json.object([]))
  let s = state.join(s, "pid2", "room:lobby", "bob", json.object([]))

  let s = state.leave_by_pid(s, "pid1")

  // pid1's entries gone, pid2's entry remains
  state.online_list(s) |> list.length |> should.equal(1)
  state.get_by_topic(s, "room:private") |> should.equal([])
}
```

**Step 2: Run tests to verify they fail**

Run: `cd beryl && gleam test`
Expected: Compile errors (functions not yet implemented)

**Step 3: Implement new, join, leave, leave_by_pid, online_list, get_by_topic**

```gleam
/// Create a new empty state for this replica
pub fn new(replica: Replica) -> State {
  State(
    replica: replica,
    context: dict.new(),
    clouds: dict.new(),
    values: dict.new(),
    replicas: dict.from_list([#(replica, Up)]),
  )
}

/// Add a tracked presence. Increments the local clock.
pub fn join(
  state: State,
  pid: String,
  topic: String,
  key: String,
  meta: json.Json,
) -> State {
  let clock = next_clock(state, state.replica)
  let tag = Tag(replica: state.replica, clock: clock)
  let entry = Entry(topic: topic, key: key, pid: pid, meta: meta)
  let new_context = dict.insert(state.context, state.replica, clock)
  let new_values = dict.insert(state.values, tag, entry)
  State(..state, context: new_context, values: new_values)
}

/// Remove a specific presence by pid, topic, and key
pub fn leave(
  state: State,
  pid: String,
  topic: String,
  key: String,
) -> State {
  let new_values =
    dict.filter(state.values, fn(_, entry) {
      !(entry.pid == pid && entry.topic == topic && entry.key == key)
    })
  State(..state, values: new_values)
}

/// Remove all presences for a pid
pub fn leave_by_pid(state: State, pid: String) -> State {
  let new_values =
    dict.filter(state.values, fn(_, entry) { entry.pid != pid })
  State(..state, values: new_values)
}

/// List all online presences across all topics (from non-down replicas)
pub fn online_list(state: State) -> List(#(String, String, String, json.Json)) {
  state.values
  |> dict.to_list()
  |> list.filter(fn(kv) {
    let #(tag, _) = kv
    is_replica_up(state, tag.replica)
  })
  |> list.map(fn(kv) {
    let #(_, entry) = kv
    #(entry.pid, entry.topic, entry.key, entry.meta)
  })
}

/// Get all presences for a topic (from non-down replicas)
pub fn get_by_topic(
  state: State,
  topic: String,
) -> List(#(String, String, json.Json)) {
  state.values
  |> dict.to_list()
  |> list.filter(fn(kv) {
    let #(tag, entry) = kv
    entry.topic == topic && is_replica_up(state, tag.replica)
  })
  |> list.map(fn(kv) {
    let #(_, entry) = kv
    #(entry.pid, entry.key, entry.meta)
  })
}

/// Get presences for a specific key within a topic
pub fn get_by_key(
  state: State,
  topic: String,
  key: String,
) -> List(#(String, json.Json)) {
  state.values
  |> dict.to_list()
  |> list.filter(fn(kv) {
    let #(tag, entry) = kv
    entry.topic == topic && entry.key == key && is_replica_up(state, tag.replica)
  })
  |> list.map(fn(kv) {
    let #(_, entry) = kv
    #(entry.pid, entry.meta)
  })
}

// Internal helpers

fn next_clock(state: State, replica: Replica) -> Clock {
  case dict.get(state.context, replica) {
    Ok(c) -> c + 1
    Error(_) -> 1
  }
}

fn is_replica_up(state: State, replica: Replica) -> Bool {
  case dict.get(state.replicas, replica) {
    Ok(Up) -> True
    Ok(Down) -> False
    Error(_) -> True  // Unknown replicas assumed up (first contact)
  }
}
```

**Step 4: Run tests**

Run: `cd beryl && gleam test`
Expected: All tests pass

**Step 5: Commit**

```
feat(beryl): implement presence CRDT new, join, leave operations
```

### Task 3: Implement merge

This is the core CRDT operation — combining remote state with local state.

**Files:**
- Modify: `beryl/src/beryl/presence/state.gleam`
- Modify: `beryl/test/presence_state_test.gleam`

**Step 1: Write failing tests**

Add to `beryl/test/presence_state_test.gleam`:
```gleam
// ── merge ────────────────────────────────────────────────────────────

pub fn merge_adds_remote_entries_test() {
  // Node A has alice, Node B has bob
  let a = state.new("node_a")
  let a = state.join(a, "pid1", "room:lobby", "alice", json.object([]))

  let b = state.new("node_b")
  let b = state.join(b, "pid2", "room:lobby", "bob", json.object([]))

  // Merge B into A
  let #(merged, _diff) = state.merge(a, b)

  // A should now see both alice and bob
  state.get_by_topic(merged, "room:lobby") |> list.length |> should.equal(2)
}

pub fn merge_is_idempotent_test() {
  let a = state.new("node_a")
  let a = state.join(a, "pid1", "room:lobby", "alice", json.object([]))

  let b = state.new("node_b")
  let b = state.join(b, "pid2", "room:lobby", "bob", json.object([]))

  // Merge twice should not duplicate
  let #(merged, _) = state.merge(a, b)
  let #(merged2, _) = state.merge(merged, b)

  state.get_by_topic(merged2, "room:lobby") |> list.length |> should.equal(2)
}

pub fn merge_observes_remote_removals_test() {
  // Node A and B both know about alice
  let a = state.new("node_a")
  let a = state.join(a, "pid1", "room:lobby", "alice", json.object([]))

  // B merges A's state to learn about alice
  let b = state.new("node_b")
  let #(b, _) = state.merge(b, a)

  // A removes alice locally
  let a = state.leave(a, "pid1", "room:lobby", "alice")

  // B merges A again — should observe the removal
  let #(merged, _) = state.merge(b, a)
  state.get_by_topic(merged, "room:lobby") |> should.equal([])
}

pub fn merge_add_wins_over_concurrent_remove_test() {
  // A has alice, B learns about alice
  let a = state.new("node_a")
  let a = state.join(a, "pid1", "room:lobby", "alice", json.object([
    #("v", json.int(1)),
  ]))

  let b = state.new("node_b")
  let #(b, _) = state.merge(b, a)

  // Concurrently: A removes alice, B re-adds alice (simulated via leave_join)
  let a = state.leave(a, "pid1", "room:lobby", "alice")
  let b = state.join(b, "pid1", "room:lobby", "alice", json.object([
    #("v", json.int(2)),
  ]))

  // When A merges B, alice should be present (add wins)
  let #(merged, _) = state.merge(a, b)
  state.get_by_topic(merged, "room:lobby") |> list.length |> should.equal(1)
}

pub fn merge_returns_diff_with_joins_test() {
  let a = state.new("node_a")
  let b = state.new("node_b")
  let b = state.join(b, "pid1", "room:lobby", "bob", json.object([]))

  let #(_merged, diff) = state.merge(a, b)

  // Diff should show bob as a join
  case dict.get(diff.joins, "room:lobby") {
    Ok(joins) -> list.length(joins) |> should.equal(1)
    Error(_) -> should.fail()
  }
}

pub fn merge_returns_diff_with_leaves_test() {
  // A knows about bob (from previous merge with B)
  let a = state.new("node_a")
  let b = state.new("node_b")
  let b = state.join(b, "pid1", "room:lobby", "bob", json.object([]))

  let #(a, _) = state.merge(a, b)

  // B removes bob
  let b = state.leave(b, "pid1", "room:lobby", "bob")

  // Merge again — diff should show bob as a leave
  let #(_merged, diff) = state.merge(a, b)
  case dict.get(diff.leaves, "room:lobby") {
    Ok(leaves) -> list.length(leaves) |> should.equal(1)
    Error(_) -> should.fail()
  }
}

pub fn merge_three_nodes_test() {
  // Three nodes, each with one user
  let a = state.new("node_a")
  let a = state.join(a, "p1", "room:lobby", "alice", json.object([]))

  let b = state.new("node_b")
  let b = state.join(b, "p2", "room:lobby", "bob", json.object([]))

  let c = state.new("node_c")
  let c = state.join(c, "p3", "room:lobby", "carol", json.object([]))

  // Merge all into A via two hops
  let #(a, _) = state.merge(a, b)
  let #(a, _) = state.merge(a, c)

  state.get_by_topic(a, "room:lobby") |> list.length |> should.equal(3)
}
```

**Step 2: Run tests to verify they fail**

Run: `cd beryl && gleam test`
Expected: Compile errors (merge not implemented)

**Step 3: Implement merge**

The merge algorithm:
1. Find entries in remote that are NOT in our causal context → these are joins
2. Find entries in our state that ARE in remote's causal context but NOT in remote's values → these are observed removals
3. Apply joins and removals, advance our context
4. Return the diff

```gleam
/// Merge remote state into local state.
/// Returns the new merged state and a diff of what changed.
pub fn merge(local: State, remote: State) -> #(State, Diff) {
  // 1. Find new entries from remote (tags we haven't seen)
  let joins =
    dict.to_list(remote.values)
    |> list.filter(fn(kv) {
      let #(tag, _) = kv
      !tag_is_in(local.context, local.clouds, tag)
    })

  // 2. Find entries we should remove (in remote's causal context but not in remote's values)
  let removes =
    dict.to_list(local.values)
    |> list.filter(fn(kv) {
      let #(tag, _) = kv
      tag.replica != local.replica
      && tag_is_in(remote.context, remote.clouds, tag)
      && !dict.has_key(remote.values, tag)
    })

  // 3. Apply changes
  let new_values =
    list.fold(removes, local.values, fn(vals, kv) {
      let #(tag, _) = kv
      dict.delete(vals, tag)
    })
  let new_values =
    list.fold(joins, new_values, fn(vals, kv) {
      let #(tag, entry) = kv
      dict.insert(vals, tag, entry)
    })

  // 4. Advance context: take max of local and remote for each replica
  let new_context = merge_contexts(local.context, remote.context)

  // 5. Merge clouds
  let new_clouds = merge_clouds(local.clouds, remote.clouds)

  // 6. Build diff
  let join_diff = entries_to_topic_diff(list.map(joins, fn(kv) { kv.1 }))
  let leave_diff = entries_to_topic_diff(list.map(removes, fn(kv) { kv.1 }))
  let diff = Diff(joins: join_diff, leaves: leave_diff)

  let new_state = State(
    ..local,
    context: new_context,
    clouds: new_clouds,
    values: new_values,
  )

  #(compact(new_state), diff)
}

/// Check if a tag is "in" a causal context (either compacted or in clouds)
fn tag_is_in(
  context: Dict(Replica, Clock),
  clouds: Dict(Replica, Set(Clock)),
  tag: Tag,
) -> Bool {
  case dict.get(context, tag.replica) {
    Ok(clock) if clock >= tag.clock -> True
    _ -> {
      case dict.get(clouds, tag.replica) {
        Ok(cloud) -> set.contains(cloud, tag.clock)
        Error(_) -> False
      }
    }
  }
}

/// Merge two vector clocks (take max per replica)
fn merge_contexts(
  a: Dict(Replica, Clock),
  b: Dict(Replica, Clock),
) -> Dict(Replica, Clock) {
  dict.combine(a, b, fn(ca, cb) {
    case ca > cb {
      True -> ca
      False -> cb
    }
  })
}

/// Merge cloud sets
fn merge_clouds(
  a: Dict(Replica, Set(Clock)),
  b: Dict(Replica, Set(Clock)),
) -> Dict(Replica, Set(Clock)) {
  dict.combine(a, b, fn(sa, sb) { set.union(sa, sb) })
}

/// Compact clouds into context where possible
///
/// If context[replica] + 1 is in the cloud, advance context and remove from cloud.
/// Repeat until no more compaction possible.
pub fn compact(state: State) -> State {
  let #(new_context, new_clouds) =
    dict.fold(state.clouds, #(state.context, state.clouds), fn(acc, replica, cloud) {
      let #(ctx, clouds) = acc
      let base = case dict.get(ctx, replica) {
        Ok(c) -> c
        Error(_) -> 0
      }
      let #(new_base, remaining) = compact_cloud(base, cloud)
      let new_ctx = case new_base > base {
        True -> dict.insert(ctx, replica, new_base)
        False -> ctx
      }
      let new_clouds = case set.size(remaining) {
        0 -> dict.delete(clouds, replica)
        _ -> dict.insert(clouds, replica, remaining)
      }
      #(new_ctx, new_clouds)
    })

  State(..state, context: new_context, clouds: new_clouds)
}

/// Compact a single cloud: advance base clock through contiguous values
fn compact_cloud(base: Clock, cloud: Set(Clock)) -> #(Clock, Set(Clock)) {
  case set.contains(cloud, base + 1) {
    True -> compact_cloud(base + 1, set.delete(cloud, base + 1))
    False -> #(base, cloud)
  }
}

/// Group entries by topic for diff reporting
fn entries_to_topic_diff(
  entries: List(Entry),
) -> Dict(String, List(#(String, String, json.Json))) {
  list.fold(entries, dict.new(), fn(acc, entry) {
    let existing = case dict.get(acc, entry.topic) {
      Ok(l) -> l
      Error(_) -> []
    }
    dict.insert(acc, entry.topic, [#(entry.key, entry.pid, entry.meta), ..existing])
  })
}
```

**Step 4: Run tests**

Run: `cd beryl && gleam test`
Expected: All merge tests pass

**Step 5: Commit**

```
feat(beryl): implement presence CRDT merge with causal context
```

### Task 4: Implement replica_up, replica_down, remove_down_replicas

**Files:**
- Modify: `beryl/src/beryl/presence/state.gleam`
- Modify: `beryl/test/presence_state_test.gleam`

**Step 1: Write failing tests**

```gleam
// ── replica lifecycle ────────────────────────────────────────────────

pub fn replica_down_hides_entries_test() {
  let a = state.new("node_a")
  let b = state.new("node_b")
  let b = state.join(b, "pid1", "room:lobby", "bob", json.object([]))

  let #(a, _) = state.merge(a, b)

  // Mark node_b as down
  let #(a, leaves) = state.replica_down(a, "node_b")

  // bob should no longer appear in queries
  state.get_by_topic(a, "room:lobby") |> should.equal([])

  // Diff should contain bob as a leave
  case dict.get(leaves.leaves, "room:lobby") {
    Ok(l) -> list.length(l) |> should.equal(1)
    Error(_) -> should.fail()
  }
}

pub fn replica_up_restores_entries_test() {
  let a = state.new("node_a")
  let b = state.new("node_b")
  let b = state.join(b, "pid1", "room:lobby", "bob", json.object([]))

  let #(a, _) = state.merge(a, b)
  let #(a, _) = state.replica_down(a, "node_b")
  let #(a, joins) = state.replica_up(a, "node_b")

  // bob should reappear
  state.get_by_topic(a, "room:lobby") |> list.length |> should.equal(1)

  // Diff should contain bob as a join
  case dict.get(joins.joins, "room:lobby") {
    Ok(j) -> list.length(j) |> should.equal(1)
    Error(_) -> should.fail()
  }
}

pub fn remove_down_replicas_permanently_deletes_test() {
  let a = state.new("node_a")
  let b = state.new("node_b")
  let b = state.join(b, "pid1", "room:lobby", "bob", json.object([]))

  let #(a, _) = state.merge(a, b)
  let #(a, _) = state.replica_down(a, "node_b")
  let a = state.remove_down_replicas(a, "node_b")

  // Even after replica_up, bob is gone permanently
  let #(a, _) = state.replica_up(a, "node_b")
  state.get_by_topic(a, "room:lobby") |> should.equal([])
}

pub fn basic_netsplit_test() {
  // A and B each have users
  let a = state.new("node_a")
  let a = state.join(a, "p1", "room:lobby", "alice", json.object([]))

  let b = state.new("node_b")
  let b = state.join(b, "p2", "room:lobby", "bob", json.object([]))

  // Merge to sync
  let #(a, _) = state.merge(a, b)
  let #(b, _) = state.merge(b, a)

  // Netsplit: A marks B as down
  let #(a, _) = state.replica_down(a, "node_b")
  state.get_by_topic(a, "room:lobby") |> list.length |> should.equal(1)  // only alice

  // Heal: A marks B as up
  let #(a, _) = state.replica_up(a, "node_b")
  state.get_by_topic(a, "room:lobby") |> list.length |> should.equal(2)  // alice + bob
}
```

**Step 2: Implement replica_down, replica_up, remove_down_replicas**

```gleam
/// Mark a replica as down. Returns entries that are now invisible (leaves).
pub fn replica_down(state: State, replica: Replica) -> #(State, Diff) {
  let new_replicas = dict.insert(state.replicas, replica, Down)
  let new_state = State(..state, replicas: new_replicas)

  // Compute what just "left" — all entries from this replica
  let hidden =
    dict.to_list(state.values)
    |> list.filter(fn(kv) { { kv.0 }.replica == replica })
    |> list.map(fn(kv) { kv.1 })

  let diff = Diff(joins: dict.new(), leaves: entries_to_topic_diff(hidden))
  #(new_state, diff)
}

/// Mark a replica as up. Returns entries that are now visible again (joins).
pub fn replica_up(state: State, replica: Replica) -> #(State, Diff) {
  let new_replicas = dict.insert(state.replicas, replica, Up)
  let new_state = State(..state, replicas: new_replicas)

  // Compute what just "joined" — all entries from this replica
  let restored =
    dict.to_list(state.values)
    |> list.filter(fn(kv) { { kv.0 }.replica == replica })
    |> list.map(fn(kv) { kv.1 })

  let diff = Diff(joins: entries_to_topic_diff(restored), leaves: dict.new())
  #(new_state, diff)
}

/// Permanently remove all entries and context for a downed replica
pub fn remove_down_replicas(state: State, replica: Replica) -> State {
  let new_values =
    dict.filter(state.values, fn(tag, _) { tag.replica != replica })
  let new_context = dict.delete(state.context, replica)
  let new_clouds = dict.delete(state.clouds, replica)
  let new_replicas = dict.delete(state.replicas, replica)
  State(..state, values: new_values, context: new_context, clouds: new_clouds, replicas: new_replicas)
}
```

**Step 3: Run tests**

Run: `cd beryl && gleam test`
Expected: All tests pass

**Step 4: Commit**

```
feat(beryl): implement presence CRDT replica lifecycle (up/down/remove)
```

### Task 5: Implement extract (delta generation)

**Files:**
- Modify: `beryl/src/beryl/presence/state.gleam`
- Modify: `beryl/test/presence_state_test.gleam`

**Step 1: Write failing tests**

```gleam
// ── extract (delta) ──────────────────────────────────────────────────

pub fn extract_produces_delta_for_new_replica_test() {
  let a = state.new("node_a")
  let a = state.join(a, "p1", "room:lobby", "alice", json.object([]))
  let a = state.join(a, "p2", "room:lobby", "bob", json.object([]))

  let b = state.new("node_b")

  // Extract what B needs from A (everything, since B has empty context)
  let delta = state.extract(a, b.replica, b.context)

  // Delta should contain both entries
  dict.size(delta.values) |> should.equal(2)
}

pub fn extract_produces_empty_delta_for_synced_replica_test() {
  let a = state.new("node_a")
  let a = state.join(a, "p1", "room:lobby", "alice", json.object([]))

  let b = state.new("node_b")
  let #(b, _) = state.merge(b, a)

  // Extract what B needs — should be nothing since B is synced
  let delta = state.extract(a, b.replica, b.context)
  dict.size(delta.values) |> should.equal(0)
}

pub fn extract_only_sends_new_entries_test() {
  let a = state.new("node_a")
  let a = state.join(a, "p1", "room:lobby", "alice", json.object([]))

  let b = state.new("node_b")
  let #(b, _) = state.merge(b, a)

  // A adds a new entry
  let a = state.join(a, "p2", "room:lobby", "bob", json.object([]))

  // Extract should only contain bob (alice already synced)
  let delta = state.extract(a, b.replica, b.context)
  dict.size(delta.values) |> should.equal(1)
}
```

**Step 2: Implement extract**

```gleam
/// Extract a minimal state (delta) containing only entries the remote
/// hasn't seen yet, based on the remote's known context.
///
/// The returned state contains:
/// - Only values with tags NOT in remote_context
/// - The local context (so remote can advance)
/// - The local clouds
pub fn extract(
  state: State,
  _remote_replica: Replica,
  remote_context: Dict(Replica, Clock),
) -> State {
  let remote_clouds = dict.new()  // Remote clouds unknown, assume empty
  let new_values =
    dict.filter(state.values, fn(tag, _) {
      !tag_is_in(remote_context, remote_clouds, tag)
    })

  State(
    ..state,
    values: new_values,
  )
}
```

**Step 3: Run tests**

Run: `cd beryl && gleam test`
Expected: All tests pass

**Step 4: Commit**

```
feat(beryl): implement presence CRDT delta extraction
```

### Task 6: Implement clocks helper and edge case tests

**Files:**
- Modify: `beryl/src/beryl/presence/state.gleam`
- Modify: `beryl/test/presence_state_test.gleam`

**Step 1: Write edge case tests**

```gleam
// ── edge cases ───────────────────────────────────────────────────────

pub fn clocks_returns_vector_clock_test() {
  let a = state.new("node_a")
  let a = state.join(a, "p1", "room:1", "k1", json.object([]))
  let a = state.join(a, "p2", "room:1", "k2", json.object([]))

  let clocks = state.clocks(a)
  case dict.get(clocks, "node_a") {
    Ok(2) -> Nil  // Two joins = clock at 2
    _ -> should.fail()
  }
}

pub fn compact_reduces_clouds_test() {
  // Manually construct a state with clouds that can be compacted
  let a = state.new("node_a")
  let a = state.join(a, "p1", "room:1", "k1", json.object([]))  // clock 1
  let a = state.join(a, "p2", "room:1", "k2", json.object([]))  // clock 2

  // After compaction, clouds for node_a should be empty
  // (context[node_a] should be 2, covering clocks 1 and 2)
  let compacted = state.compact(a)
  case dict.get(compacted.clouds, "node_a") {
    Ok(cloud) -> set.size(cloud) |> should.equal(0)
    Error(_) -> Nil  // Cloud deleted entirely, also fine
  }
}

pub fn merge_with_empty_state_test() {
  let a = state.new("node_a")
  let a = state.join(a, "p1", "room:1", "k1", json.object([]))

  let empty = state.new("node_b")

  // Merging empty into non-empty should be a no-op
  let #(merged, diff) = state.merge(a, empty)
  state.get_by_topic(merged, "room:1") |> list.length |> should.equal(1)
  dict.size(diff.joins) |> should.equal(0)
  dict.size(diff.leaves) |> should.equal(0)
}

pub fn get_by_key_multiple_pids_test() {
  let a = state.new("node_a")
  let a = state.join(a, "pid1", "room:lobby", "user:alice", json.object([
    #("device", json.string("desktop")),
  ]))
  let a = state.join(a, "pid2", "room:lobby", "user:alice", json.object([
    #("device", json.string("mobile")),
  ]))

  let results = state.get_by_key(a, "room:lobby", "user:alice")
  list.length(results) |> should.equal(2)
}

pub fn leave_only_removes_matching_entry_test() {
  let a = state.new("node_a")
  let a = state.join(a, "pid1", "room:lobby", "alice", json.object([]))
  let a = state.join(a, "pid1", "room:lobby", "bob", json.object([]))
  let a = state.leave(a, "pid1", "room:lobby", "alice")

  state.get_by_topic(a, "room:lobby") |> list.length |> should.equal(1)
}

pub fn joins_propagate_through_intermediate_node_test() {
  // A -> B -> C chain: A's join should reach C via B
  let a = state.new("node_a")
  let a = state.join(a, "p1", "room:lobby", "alice", json.object([]))

  let b = state.new("node_b")
  let #(b, _) = state.merge(b, a)

  let c = state.new("node_c")
  let #(c, _) = state.merge(c, b)

  // C should see alice
  state.get_by_topic(c, "room:lobby") |> list.length |> should.equal(1)
}

pub fn removes_propagate_through_intermediate_node_test() {
  // All three nodes sync, then A removes, propagate via B to C
  let a = state.new("node_a")
  let a = state.join(a, "p1", "room:lobby", "alice", json.object([]))

  let b = state.new("node_b")
  let #(b, _) = state.merge(b, a)

  let c = state.new("node_c")
  let #(c, _) = state.merge(c, b)

  // A removes alice
  let a = state.leave(a, "p1", "room:lobby", "alice")

  // Propagate: A -> B -> C
  let #(b, _) = state.merge(b, a)
  let #(c, _) = state.merge(c, b)

  state.get_by_topic(c, "room:lobby") |> should.equal([])
}
```

**Step 2: Add clocks function**

```gleam
/// Get the current vector clock
pub fn clocks(state: State) -> Dict(Replica, Clock) {
  state.context
}
```

**Step 3: Run tests**

Run: `cd beryl && gleam test`
Expected: All tests pass

**Step 4: Commit**

```
feat(beryl): add CRDT edge case tests and clocks helper

Covers: multi-node propagation, idempotent merges, netsplit/heal,
multiple PIDs per key, and cloud compaction.
```

---

## Phase 1: Extract Levee-Specific Code

### Task 7: Create levee_channels Gleam package

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

### Task 8: Move document_channel and runtime to levee_channels

**Files:**
- Move: `beryl/src/beryl/levee/document_channel.gleam` → `levee_channels/src/levee_channels/document_channel.gleam`
- Move: `beryl/src/beryl/levee/runtime.gleam` → `levee_channels/src/levee_channels/runtime.gleam`
- Move: `beryl/src/levee_document_ffi.erl` → `levee_channels/src/levee_document_ffi.erl`
- Move: `beryl/src/levee_document_ffi_helpers.erl` → `levee_channels/src/levee_document_ffi_helpers.erl`
- Create: `levee_channels/src/levee_channels_ffi.erl` (identity function)

**Step 1: Copy files and create FFI**

```bash
mkdir -p levee_channels/src/levee_channels
cp beryl/src/beryl/levee/document_channel.gleam levee_channels/src/levee_channels/document_channel.gleam
cp beryl/src/beryl/levee/runtime.gleam levee_channels/src/levee_channels/runtime.gleam
cp beryl/src/levee_document_ffi.erl levee_channels/src/levee_document_ffi.erl
cp beryl/src/levee_document_ffi_helpers.erl levee_channels/src/levee_document_ffi_helpers.erl
```

Create `levee_channels/src/levee_channels_ffi.erl`:
```erlang
-module(levee_channels_ffi).
-export([identity/1]).

identity(X) -> X.
```

**Step 2: Update imports in document_channel.gleam**

- Change `@external(erlang, "beryl_ffi", "identity")` to `@external(erlang, "levee_channels_ffi", "identity")`
- Keep `beryl/` imports as-is (beryl is a dependency)

**Step 3: Update imports in runtime.gleam**

- Change `import beryl/levee/document_channel` to `import levee_channels/document_channel`

**Step 4: Verify levee_channels compiles**

Run: `cd levee_channels && gleam check`
Expected: 0 errors

**Step 5: Commit**

```
refactor(levee_channels): move document_channel and runtime from beryl
```

### Task 9: Remove levee-specific code from beryl and update Elixir integration

**Files:**
- Delete: `beryl/src/beryl/levee/` (entire directory)
- Delete: `beryl/src/levee_document_ffi.erl`
- Delete: `beryl/src/levee_document_ffi_helpers.erl`
- Modify: `lib/levee/channels.ex` — Change `:beryl@levee@runtime` to `:levee_channels@runtime`
- Modify: `lib/levee_web/socket_handler.ex` — Same module reference change

**Step 1: Remove files from beryl**

```bash
rm -rf beryl/src/beryl/levee/
rm -f beryl/src/levee_document_ffi.erl
rm -f beryl/src/levee_document_ffi_helpers.erl
```

**Step 2: Verify beryl compiles clean**

Run: `cd beryl && gleam check && gleam test`
Expected: All existing tests pass, no levee references

**Step 3: Update Elixir modules**

In `lib/levee/channels.ex`: change `@compile {:no_warn_undefined, [:beryl@levee@runtime]}` and all calls to use `:levee_channels@runtime`

In `lib/levee_web/socket_handler.ex`: same change

**Step 4: Update build pipeline** (mix.exs/justfile) to include `levee_channels` in Gleam builds

**Step 5: Full test run**

Run: `just build && just test`
Expected: All 138+ tests pass

**Step 6: Verify clean separation**

Run: `rg -i "levee|document" beryl/src/ --type gleam --type erlang`
Expected: No matches

**Step 7: Commit**

```
refactor: extract levee-specific code from beryl, update Elixir integration

beryl is now a pure generic channels library. All levee-specific
code (DocumentChannel, runtime, FFIs) lives in levee_channels.
```

---

## Phase 2: PubSub via Erlang pg

### Task 10: Create beryl/pubsub.gleam

**Files:**
- Create: `beryl/src/beryl/pubsub.gleam`
- Create: `beryl/src/beryl/pubsub_ffi.erl`

**Step 1: Write the Erlang FFI for pg module**

`beryl/src/beryl/pubsub_ffi.erl`:
```erlang
-module(beryl_pubsub_ffi).
-export([start_pg_scope/1, join_group/3, leave_group/3,
         get_members/2, get_local_members/2, send_to_pid/2]).

start_pg_scope(Scope) -> pg:start(Scope).
join_group(Scope, Group, Pid) -> pg:join(Scope, Group, Pid).
leave_group(Scope, Group, Pid) -> pg:leave(Scope, Group, Pid).
get_members(Scope, Group) -> pg:get_members(Scope, Group).
get_local_members(Scope, Group) -> pg:get_local_members(Scope, Group).
send_to_pid(Pid, Msg) -> Pid ! Msg, nil.
```

**Step 2: Write the Gleam module**

See full implementation in the earlier plan draft. Key API:
- `start(config)` / `default_config()` / `config_with_scope(name)`
- `subscribe(ps, topic)` / `unsubscribe(ps, topic)`
- `broadcast(ps, topic, event, payload)` / `broadcast_from(ps, from, topic, event, payload)`
- `local_broadcast(ps, topic, event, payload)`
- `subscribers(ps, topic)` / `subscriber_count(ps, topic)`

**Step 3: Write tests**

```gleam
pub fn pubsub_start_test() { ... }
pub fn pubsub_subscribe_and_count_test() { ... }
pub fn pubsub_unsubscribe_test() { ... }
```

**Step 4: Verify and commit**

Run: `cd beryl && gleam test`
Expected: All tests pass

```
feat(beryl): add PubSub module using Erlang pg for distributed messaging
```

### Task 11: Integrate PubSub with beryl config

**Files:**
- Modify: `beryl/src/beryl.gleam` — Add optional PubSub to Config/Channels, `with_pubsub()` builder

**Step 1: Update types and start()**

Add `pubsub: Option(PubSub)` to Config and Channels. Add `with_pubsub(config, pubsub)` builder. Update `broadcast()` to also push through PubSub when available.

**Step 2: Run all tests**

Run: `cd beryl && gleam test`
Expected: All pass (PubSub is optional, defaults to None)

**Step 3: Commit**

```
feat(beryl): integrate PubSub with coordinator for distributed broadcasts
```

---

## Phase 3: Channel Groups

### Task 12: Create beryl/group.gleam with tests

**Files:**
- Create: `beryl/src/beryl/group.gleam`

**Step 1: Implement the full group module**

See full implementation in earlier plan draft. Key API:
- `start()` → `Groups`
- `create(groups, name)` / `delete(groups, name)`
- `add(groups, group_name, topic)` / `remove(groups, group_name, topic)`
- `topics(groups, group_name)` / `list_groups(groups)`
- `broadcast(groups, channels, group_name, event, payload)`

**Step 2: Write tests**

```gleam
pub fn group_create_and_list_test() { ... }
pub fn group_add_topics_test() { ... }
pub fn group_remove_topic_test() { ... }
pub fn group_not_found_test() { ... }
pub fn group_already_exists_test() { ... }
pub fn group_delete_test() { ... }
```

**Step 3: Verify and commit**

```
feat(beryl): add channel groups for multi-topic broadcasting
```

---

## Phase 4: Presence Actor (wraps CRDT)

### Task 13: Create beryl/presence.gleam wrapping state.gleam in an actor

**Files:**
- Create: `beryl/src/beryl/presence.gleam`

Now that `beryl/presence/state.gleam` is solid, wrap it in an OTP actor that:
- Handles `track`/`untrack` calls by calling `state.join`/`state.leave`
- Periodically broadcasts state via PubSub for cross-node replication
- Receives remote state and calls `state.merge`
- Pushes `"presence_state"` and `"presence_diff"` events to channel subscribers

**Step 1: Implement actor**

Key API:
- `start(config)` — Start presence actor with PubSub for replication
- `track(presence, topic, key, meta)` → `Result(String, Nil)`
- `untrack(presence, topic, key, ref)`
- `list(presence, topic)` → `List(PresenceEntry)`
- `get_by_key(presence, topic, key)` → `Option(PresenceEntry)`

**Step 2: Write integration tests**

**Step 3: Commit**

```
feat(beryl): add presence actor wrapping CRDT state module
```

---

## Phase 5: Documentation & Integration

### Task 14: Update beryl.gleam docs and full integration test

**Files:**
- Modify: `beryl/src/beryl.gleam` — Update module docs

**Step 1: Update docs to mention all features**

**Step 2: Full build and test**

Run: `just build && just test`
Expected: All tests pass

**Step 3: Commit**

```
docs(beryl): update module documentation with full feature set
```

---

## Summary

| Task | Description | Phase |
|------|-------------|-------|
| 1-6 | **Pure CRDT data structure** with comprehensive tests | Phase 0: CRDT |
| 7-9 | Extract levee-specific code into `levee_channels` | Phase 1: Extraction |
| 10-11 | PubSub module using Erlang pg | Phase 2: PubSub |
| 12 | Channel Groups | Phase 3: Groups |
| 13 | Presence actor wrapping CRDT | Phase 4: Presence Actor |
| 14 | Documentation and integration | Phase 5: Docs |

**Phase 0 is the critical path** — 6 tasks building a pure, well-tested CRDT before any integration. The test suite covers: basic ops, merge semantics, idempotency, add-wins conflict resolution, netsplit/heal, multi-hop propagation, delta extraction, and cloud compaction.

Rate limiting is deferred to a separate effort using the library extracted from birch.
