import fluid_protocol
import fluid_protocol/sequencing
import gleeunit
import gleeunit/should

pub fn main() -> Nil {
  gleeunit.main()
}

// Test new sequence state starts at 0
pub fn new_sequence_state_test() {
  let state = fluid_protocol.new_sequence_state()
  fluid_protocol.current_sn(state) |> should.equal(0)
  fluid_protocol.current_msn(state) |> should.equal(0)
  fluid_protocol.client_count(state) |> should.equal(0)
}

// Test client join
pub fn client_join_test() {
  let state = fluid_protocol.new_sequence_state()
  let state = fluid_protocol.client_join(state, "client-1", 0)

  fluid_protocol.client_count(state) |> should.equal(1)
  fluid_protocol.is_client_connected(state, "client-1") |> should.be_true()
  fluid_protocol.is_client_connected(state, "client-2") |> should.be_false()
}

// Test sequence number assignment
pub fn assign_sequence_number_test() {
  let state = fluid_protocol.new_sequence_state()
  let state = fluid_protocol.client_join(state, "client-1", 0)

  // Assign first sequence number
  case sequencing.assign_sequence_number(state, "client-1", 1, 0) {
    sequencing.SequenceOk(new_state, assigned_sn, msn) -> {
      assigned_sn |> should.equal(1)
      msn |> should.equal(0)
      fluid_protocol.current_sn(new_state) |> should.equal(1)
    }
    sequencing.SequenceError(_) -> {
      should.fail()
    }
  }
}

// Test multiple ops increment SN correctly
pub fn multiple_ops_test() {
  let state = fluid_protocol.new_sequence_state()
  let state = fluid_protocol.client_join(state, "client-1", 0)

  // First op
  let state = case sequencing.assign_sequence_number(state, "client-1", 1, 0) {
    sequencing.SequenceOk(s, sn, _) -> {
      sn |> should.equal(1)
      s
    }
    sequencing.SequenceError(_) -> panic
  }

  // Second op
  let state = case sequencing.assign_sequence_number(state, "client-1", 2, 1) {
    sequencing.SequenceOk(s, sn, _) -> {
      sn |> should.equal(2)
      s
    }
    sequencing.SequenceError(_) -> panic
  }

  fluid_protocol.current_sn(state) |> should.equal(2)
}

// Test invalid CSN is rejected
pub fn invalid_csn_test() {
  let state = fluid_protocol.new_sequence_state()
  let state = fluid_protocol.client_join(state, "client-1", 0)

  // First op with CSN 1
  let state = case sequencing.assign_sequence_number(state, "client-1", 1, 0) {
    sequencing.SequenceOk(s, _, _) -> s
    sequencing.SequenceError(_) -> panic
  }

  // Try to submit with CSN 1 again (should fail)
  case sequencing.assign_sequence_number(state, "client-1", 1, 1) {
    sequencing.SequenceOk(_, _, _) -> should.fail()
    sequencing.SequenceError(reason) -> {
      case reason {
        sequencing.InvalidCsn(_, _) -> should.be_ok(Ok(Nil))
        _ -> should.fail()
      }
    }
  }
}

// Test client leave
pub fn client_leave_test() {
  let state = fluid_protocol.new_sequence_state()
  let state = fluid_protocol.client_join(state, "client-1", 0)
  let state = fluid_protocol.client_join(state, "client-2", 0)

  fluid_protocol.client_count(state) |> should.equal(2)

  let state = fluid_protocol.client_leave(state, "client-1")

  fluid_protocol.client_count(state) |> should.equal(1)
  fluid_protocol.is_client_connected(state, "client-1") |> should.be_false()
  fluid_protocol.is_client_connected(state, "client-2") |> should.be_true()
}

// Test MSN calculation with multiple clients
pub fn msn_calculation_test() {
  let state = fluid_protocol.new_sequence_state()

  // Client 1 joins at RSN 0
  let state = fluid_protocol.client_join(state, "client-1", 0)

  // Client 1 submits op (CSN 1, RSN 0)
  let state = case sequencing.assign_sequence_number(state, "client-1", 1, 0) {
    sequencing.SequenceOk(s, _, msn) -> {
      // MSN should still be 0 (client-1's RSN was 0)
      msn |> should.equal(0)
      s
    }
    sequencing.SequenceError(_) -> panic
  }

  // Client 2 joins at current SN (1)
  let state = fluid_protocol.client_join(state, "client-2", 1)

  // Client 2 submits op (CSN 1, RSN 1)
  let state = case sequencing.assign_sequence_number(state, "client-2", 1, 1) {
    sequencing.SequenceOk(s, _, msn) -> {
      // MSN should still be 0 (client-1's last RSN was 0)
      msn |> should.equal(0)
      s
    }
    sequencing.SequenceError(_) -> panic
  }

  // Client 1 submits op (CSN 2, RSN 2) - now caught up
  case sequencing.assign_sequence_number(state, "client-1", 2, 2) {
    sequencing.SequenceOk(_, _, msn) -> {
      // MSN should advance to 1 (min of client-1's RSN=2, client-2's RSN=1)
      msn |> should.equal(1)
    }
    sequencing.SequenceError(_) -> panic
  }
}
