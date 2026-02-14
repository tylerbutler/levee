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

// ── Phoenix-inspired merge tests ────────────────────────────────────
// Ported from Phoenix.Tracker.StateTest

/// Phoenix test: "users from other servers merge" — full lifecycle
/// merge, idempotent re-merge, observe remove, new join after remove,
/// and metadata update via leave+join
pub fn phoenix_full_merge_lifecycle_test() {
  let a = state.new("node_a")
  let b = state.new("node_b")

  let a = state.join(a, "pid_alice", "lobby", "alice", json.object([]))
  let b = state.join(b, "pid_bob", "lobby", "bob", json.object([]))

  // Merge B into A — bob appears as join
  let #(a, diff) = state.merge(a, b)
  state.online_list(a) |> list.length |> should.equal(2)
  case dict.get(diff.joins, "lobby") {
    Ok(joins) -> list.length(joins) |> should.equal(1)
    Error(_) -> should.fail()
  }

  // Merge B into A again — idempotent, no new events
  let #(a2, diff2) = state.merge(a, b)
  dict.size(diff2.joins) |> should.equal(0)
  dict.size(diff2.leaves) |> should.equal(0)
  state.online_list(a2) |> list.length |> should.equal(2)

  // Merge A into B — alice appears as join
  let #(b, diff3) = state.merge(b, a)
  case dict.get(diff3.joins, "lobby") {
    Ok(joins) -> list.length(joins) |> should.equal(1)
    Error(_) -> should.fail()
  }
  // Re-merge is idempotent
  let #(_b2, diff4) = state.merge(b, a)
  dict.size(diff4.joins) |> should.equal(0)

  // A removes alice, B observes via merge
  let a = state.leave(a, "pid_alice", "lobby", "alice")
  let #(b, diff5) = state.merge(b, a)
  case dict.get(diff5.leaves, "lobby") {
    Ok(leaves) -> list.length(leaves) |> should.equal(1)
    Error(_) -> should.fail()
  }
  state.online_list(b) |> list.length |> should.equal(1)

  // B adds carol
  let b = state.join(b, "pid_carol", "lobby", "carol", json.object([]))
  state.online_list(b) |> list.length |> should.equal(2)

  // A merges B — gets carol
  let #(a, diff6) = state.merge(a, b)
  case dict.get(diff6.joins, "lobby") {
    Ok(joins) -> list.length(joins) |> should.equal(1)
    Error(_) -> should.fail()
  }

  // After full sync both nodes agree
  state.online_list(a) |> list.length |> should.equal(
    state.online_list(b) |> list.length,
  )
}

/// Phoenix test: metadata update via leave+join (leave_join pattern)
pub fn phoenix_update_via_leave_join_test() {
  let a = state.new("node_a")
  let b = state.new("node_b")

  let b =
    state.join(b, "pid_carol", "lobby", "carol", json.object([
      #("status", json.string("online")),
    ]))

  // Sync A with B
  let #(a, _) = state.merge(a, b)

  // B updates carol by leaving then rejoining with new meta
  let b = state.leave(b, "pid_carol", "lobby", "carol")
  let b =
    state.join(b, "pid_carol", "lobby", "carol", json.object([
      #("status", json.string("away")),
    ]))

  // Merge into A — should see a leave and a join for carol
  let #(_a, diff) = state.merge(a, b)
  case dict.get(diff.joins, "lobby") {
    Ok(joins) -> list.length(joins) |> should.equal(1)
    Error(_) -> should.fail()
  }
  case dict.get(diff.leaves, "lobby") {
    Ok(leaves) -> list.length(leaves) |> should.equal(1)
    Error(_) -> should.fail()
  }
}

/// Phoenix test: "basic netsplit" — replica down during mutations,
/// merge is no-op while down, replica_up restores
pub fn phoenix_netsplit_with_mutations_test() {
  let a = state.new("node_a")
  let b = state.new("node_b")

  let a = state.join(a, "pid_alice", "lobby", "alice", json.object([]))
  let b = state.join(b, "pid_bob", "lobby", "bob", json.object([]))

  // Sync
  let #(a, _) = state.merge(a, b)
  state.online_list(a) |> list.length |> should.equal(2)

  // A does some mutations
  let a = state.join(a, "pid_carol", "lobby", "carol", json.object([]))
  let a = state.leave(a, "pid_alice", "lobby", "alice")
  let a = state.join(a, "pid_david", "lobby", "david", json.object([]))

  // Netsplit: A marks B as down
  let #(a, down_diff) = state.replica_down(a, "node_b")
  // bob should show as a leave
  case dict.get(down_diff.leaves, "lobby") {
    Ok(leaves) -> list.length(leaves) |> should.equal(1)
    Error(_) -> should.fail()
  }
  // Only carol and david visible (alice left, bob is down)
  state.online_list(a) |> list.length |> should.equal(2)

  // Merge while down is no-op for visibility
  let #(a, noop_diff) = state.merge(a, b)
  dict.size(noop_diff.joins) |> should.equal(0)
  state.online_list(a) |> list.length |> should.equal(2)

  // Heal: A marks B as up — bob reappears
  let #(a, up_diff) = state.replica_up(a, "node_b")
  case dict.get(up_diff.joins, "lobby") {
    Ok(joins) -> list.length(joins) |> should.equal(1)
    Error(_) -> should.fail()
  }
  // carol, david, bob
  state.online_list(a) |> list.length |> should.equal(3)
}

/// Phoenix test: "joins are observed via other node" (3-node with netsplit)
pub fn phoenix_joins_via_intermediate_node_test() {
  let a = state.new("node_a")
  let b = state.new("node_b")
  let c = state.new("node_c")

  let a = state.join(a, "pid_alice", "lobby", "alice", json.object([]))

  // C learns about alice from A
  let #(c, _) = state.merge(c, a)
  state.get_by_topic(c, "lobby") |> list.length |> should.equal(1)

  // Netsplit between A and C
  let #(a, _) = state.replica_down(a, "node_c")
  let #(c, _) = state.replica_down(c, "node_a")

  // A adds bob
  let a = state.join(a, "pid_bob", "lobby", "bob", json.object([]))

  // B merges A's full state — gets both alice and bob
  let #(b, _) = state.merge(b, a)
  state.get_by_topic(b, "lobby") |> list.length |> should.equal(2)

  // C merges B — should get bob (which C hasn't seen yet)
  let #(_c, diff) = state.merge(c, b)
  case dict.get(diff.joins, "lobby") {
    Ok(joins) -> list.length(joins) |> should.equal(1)
    Error(_) -> should.fail()
  }
}

/// Phoenix test: "removes are observed via other node" (3-node with netsplit)
/// Tests that removes propagate through an intermediate node even during netsplit
pub fn phoenix_removes_via_intermediate_node_test() {
  let a = state.new("node_a")
  let b = state.new("node_b")
  let c = state.new("node_c")

  let a = state.join(a, "pid_alice", "lobby", "alice", json.object([]))

  // All nodes learn about alice
  let #(b, _) = state.merge(b, a)
  let #(c, _) = state.merge(c, a)

  // B adds bob
  let b = state.join(b, "pid_bob", "lobby", "bob", json.object([]))

  // A and C learn about bob
  let #(a, _) = state.merge(a, b)
  let #(c, _) = state.merge(c, b)
  state.get_by_topic(c, "lobby") |> list.length |> should.equal(2)

  // Netsplit between A and C (B can talk to both)
  let #(a, _) = state.replica_down(a, "node_c")
  let #(c, _) = state.replica_down(c, "node_a")

  // A removes alice
  let a = state.leave(a, "pid_alice", "lobby", "alice")

  // B observes remove via A
  let #(b, _) = state.merge(b, a)

  // C observes remove via B (not directly from A due to netsplit)
  let #(_c, diff) = state.merge(c, b)
  case dict.get(diff.leaves, "lobby") {
    Ok(leaves) -> list.length(leaves) |> should.equal(1)
    Error(_) -> should.fail()
  }
}

/// Phoenix test: "get_by_topic" with multiple replicas and down/up filtering
pub fn phoenix_get_by_topic_with_replica_status_test() {
  let s1 = state.new("node1")
  let s2 = state.new("node2")
  let s3 = state.new("node3")

  // Each node adds entries
  let s1 = state.join(s1, "pid1", "topic", "key1", json.object([]))
  let s1 = state.join(s1, "pid1", "topic", "key2", json.object([]))
  let s2 = state.join(s2, "pid2", "topic", "user2", json.object([]))
  let s3 = state.join(s3, "pid3", "topic", "user3", json.object([]))

  // s1 sees only local entries
  state.get_by_topic(s1, "topic") |> list.length |> should.equal(2)

  // Merge all into s1
  let #(s1, _) = state.merge(s1, s2)
  let #(s1, _) = state.merge(s1, s3)

  // All 4 entries visible
  state.get_by_topic(s1, "topic") |> list.length |> should.equal(4)

  // One replica down — 3 entries visible
  let #(s1, _) = state.replica_down(s1, "node2")
  state.get_by_topic(s1, "topic") |> list.length |> should.equal(3)

  // Two replicas down — 2 entries visible (only local)
  let #(s1, _) = state.replica_down(s1, "node3")
  state.get_by_topic(s1, "topic") |> list.length |> should.equal(2)

  // Different topic returns empty
  state.get_by_topic(s1, "another:topic") |> should.equal([])
}

/// Phoenix test: "get_by_key" with multiple pids for same key
pub fn phoenix_get_by_key_test() {
  let s = state.new("node1")

  state.get_by_key(s, "topic", "key1") |> should.equal([])

  let s =
    state.join(s, "pid1", "topic", "key1", json.object([
      #("device", json.string("browser")),
    ]))
  let s =
    state.join(s, "pid2", "topic", "key1", json.object([
      #("device", json.string("ios")),
    ]))
  let s =
    state.join(s, "pid2", "topic", "key2", json.object([
      #("device", json.string("ios")),
    ]))

  // Two entries for key1
  state.get_by_key(s, "topic", "key1") |> list.length |> should.equal(2)

  // Different topic/key returns empty
  state.get_by_key(s, "another_topic", "key1") |> should.equal([])
  state.get_by_key(s, "topic", "another_key") |> should.equal([])
}

/// Phoenix test: "remove_down_replicas" — permanent deletion
pub fn phoenix_remove_down_replicas_test() {
  let s1 = state.new("node1")
  let s2 = state.new("node2")

  let s1 = state.join(s1, "pid_alice", "lobby", "alice", json.object([]))
  let s2 = state.join(s2, "pid_bob", "lobby", "bob", json.object([]))

  // Sync
  let #(s2, _) = state.merge(s2, s1)
  state.online_list(s2) |> list.length |> should.equal(2)

  // Mark node1 as down
  let #(s2, _) = state.replica_down(s2, "node1")

  // Permanently remove node1
  let s2 = state.remove_down_replicas(s2, "node1")

  // Even after replica_up, alice is gone permanently
  let #(s2, _) = state.replica_up(s2, "node1")
  state.online_list(s2) |> list.length |> should.equal(1)
}
