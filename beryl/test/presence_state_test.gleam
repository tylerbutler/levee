import beryl/presence/state
import gleam/dict
import gleam/json
import gleam/list
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
  let s =
    state.join(s, "pid1", "room:lobby", "user:alice", json.object([
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
  let a =
    state.join(a, "pid1", "room:lobby", "alice", json.object([
      #("v", json.int(1)),
    ]))

  let b = state.new("node_b")
  let #(b, _) = state.merge(b, a)

  // Concurrently: A removes alice, B re-adds alice
  let a = state.leave(a, "pid1", "room:lobby", "alice")
  let b =
    state.join(b, "pid1", "room:lobby", "alice", json.object([
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
