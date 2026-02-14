//// Presence State - Pure CRDT for distributed presence tracking
////
//// A causal-context add-wins observed-remove set, inspired by Phoenix.Tracker.State.
//// This module is a pure data structure with no actors or side effects.
////
//// Each node (replica) tracks its own presences authoritatively. State is
//// replicated by extracting deltas and merging them at remote replicas.
//// Conflicts are resolved causally: adds win over concurrent removes.

import gleam/dict.{type Dict}
import gleam/json
import gleam/list
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

// ── Core operations ─────────────────────────────────────────────────

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
      case entry.pid == pid && entry.topic == topic && entry.key == key {
        True -> False
        False -> True
      }
    })
  State(..state, values: new_values)
}

/// Remove all presences for a pid
pub fn leave_by_pid(state: State, pid: String) -> State {
  let new_values =
    dict.filter(state.values, fn(_, entry) { entry.pid != pid })
  State(..state, values: new_values)
}

// ── Query operations ────────────────────────────────────────────────

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
    entry.topic == topic
    && entry.key == key
    && is_replica_up(state, tag.replica)
  })
  |> list.map(fn(kv) {
    let #(_, entry) = kv
    #(entry.pid, entry.meta)
  })
}

// ── Internal helpers ────────────────────────────────────────────────

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
    // Unknown replicas assumed up (first contact)
    Error(_) -> True
  }
}
