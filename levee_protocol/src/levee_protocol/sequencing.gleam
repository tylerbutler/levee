/// Sequence number management for Fluid Framework protocol
///
/// This module handles:
/// - CSN (Client Sequence Number): Per-client, monotonically increasing from 1
/// - SN (Sequence Number): Server-assigned, globally monotonically increasing
/// - RSN (Reference Sequence Number): Client's last-seen SN when creating op
/// - MSN (Minimum Sequence Number): min(RSN of all connected clients)
import gleam/dict.{type Dict}
import gleam/int
import gleam/list

/// Per-client sequence state
pub type ClientSequenceState {
  ClientSequenceState(
    /// Last CSN received from this client
    last_csn: Int,
    /// Last RSN we know for this client (from their most recent op or join)
    last_rsn: Int,
  )
}

/// Document-level sequence state
pub type SequenceState {
  SequenceState(
    /// Current sequence number (last assigned)
    sequence_number: Int,
    /// Current minimum sequence number
    minimum_sequence_number: Int,
    /// Per-client sequence tracking
    client_states: Dict(String, ClientSequenceState),
  )
}

/// Result of assigning a sequence number
pub type SequenceResult {
  SequenceOk(
    /// New state after assignment
    state: SequenceState,
    /// Assigned sequence number
    assigned_sn: Int,
    /// Updated MSN
    msn: Int,
  )
  SequenceError(reason: SequenceError)
}

/// Errors that can occur during sequencing
pub type SequenceError {
  /// CSN is not greater than last received
  InvalidCsn(expected_greater_than: Int, received: Int)
  /// RSN is greater than current SN (impossible)
  InvalidRsn(current_sn: Int, received_rsn: Int)
  /// Unknown client (not joined)
  UnknownClient(client_id: String)
}

/// Create initial sequence state for a new document
pub fn new() -> SequenceState {
  SequenceState(
    sequence_number: 0,
    minimum_sequence_number: 0,
    client_states: dict.new(),
  )
}

/// Create sequence state from existing document state
pub fn from_checkpoint(sn: Int, msn: Int) -> SequenceState {
  SequenceState(
    sequence_number: sn,
    minimum_sequence_number: msn,
    client_states: dict.new(),
  )
}

/// Register a new client joining the session
///
/// The client's initial RSN is set from the current SN
pub fn client_join(
  state: SequenceState,
  client_id: String,
  join_rsn: Int,
) -> SequenceState {
  let client_state = ClientSequenceState(last_csn: 0, last_rsn: join_rsn)

  let new_clients = dict.insert(state.client_states, client_id, client_state)

  // Recalculate MSN with new client
  let new_msn = calculate_msn(new_clients, state.minimum_sequence_number)

  SequenceState(
    sequence_number: state.sequence_number,
    minimum_sequence_number: new_msn,
    client_states: new_clients,
  )
}

/// Remove a client from the session
///
/// The client is removed from MSN calculation
pub fn client_leave(state: SequenceState, client_id: String) -> SequenceState {
  let new_clients = dict.delete(state.client_states, client_id)

  // Recalculate MSN without this client
  let new_msn = calculate_msn(new_clients, state.minimum_sequence_number)

  SequenceState(
    sequence_number: state.sequence_number,
    minimum_sequence_number: new_msn,
    client_states: new_clients,
  )
}

/// Assign a sequence number to an incoming operation
///
/// Validates:
/// - Client is known (has joined)
/// - CSN is monotonically increasing for this client
/// - RSN is not greater than current SN
pub fn assign_sequence_number(
  state: SequenceState,
  client_id: String,
  csn: Int,
  rsn: Int,
) -> SequenceResult {
  // Look up client state
  case dict.get(state.client_states, client_id) {
    Error(Nil) -> SequenceError(UnknownClient(client_id))

    Ok(client_state) -> {
      // Validate CSN is increasing
      case csn > client_state.last_csn {
        False ->
          SequenceError(InvalidCsn(
            expected_greater_than: client_state.last_csn,
            received: csn,
          ))

        True -> {
          // Validate RSN is not from the future
          case rsn > state.sequence_number {
            True ->
              SequenceError(InvalidRsn(
                current_sn: state.sequence_number,
                received_rsn: rsn,
              ))

            False -> {
              // Assign next sequence number
              let new_sn = state.sequence_number + 1

              // Update client state
              let new_client_state =
                ClientSequenceState(last_csn: csn, last_rsn: rsn)

              let new_clients =
                dict.insert(state.client_states, client_id, new_client_state)

              // Recalculate MSN
              let new_msn =
                calculate_msn(new_clients, state.minimum_sequence_number)

              let new_state =
                SequenceState(
                  sequence_number: new_sn,
                  minimum_sequence_number: new_msn,
                  client_states: new_clients,
                )

              SequenceOk(state: new_state, assigned_sn: new_sn, msn: new_msn)
            }
          }
        }
      }
    }
  }
}

/// Calculate MSN from current client states
///
/// MSN = min(last_rsn of all connected clients)
/// MSN can only increase, never decrease
fn calculate_msn(
  client_states: Dict(String, ClientSequenceState),
  current_msn: Int,
) -> Int {
  let rsns =
    client_states
    |> dict.values()
    |> list.map(fn(cs) { cs.last_rsn })

  case list.reduce(rsns, int.min) {
    // No clients connected - MSN stays the same
    Error(Nil) -> current_msn
    // MSN is minimum RSN, but can never decrease
    Ok(min_rsn) -> int.max(min_rsn, current_msn)
  }
}

/// Update a client's RSN without submitting an op (e.g., from NoOp)
pub fn update_client_rsn(
  state: SequenceState,
  client_id: String,
  new_rsn: Int,
) -> Result(SequenceState, SequenceError) {
  case dict.get(state.client_states, client_id) {
    Error(Nil) -> Error(UnknownClient(client_id))

    Ok(client_state) -> {
      // RSN can only increase
      let updated_rsn = int.max(client_state.last_rsn, new_rsn)
      let new_client_state =
        ClientSequenceState(..client_state, last_rsn: updated_rsn)

      let new_clients =
        dict.insert(state.client_states, client_id, new_client_state)

      let new_msn = calculate_msn(new_clients, state.minimum_sequence_number)

      Ok(SequenceState(
        sequence_number: state.sequence_number,
        minimum_sequence_number: new_msn,
        client_states: new_clients,
      ))
    }
  }
}

/// Get the current sequence number
pub fn current_sn(state: SequenceState) -> Int {
  state.sequence_number
}

/// Get the current minimum sequence number
pub fn current_msn(state: SequenceState) -> Int {
  state.minimum_sequence_number
}

/// Get the number of connected clients
pub fn client_count(state: SequenceState) -> Int {
  dict.size(state.client_states)
}

/// Check if a client is connected
pub fn is_client_connected(state: SequenceState, client_id: String) -> Bool {
  dict.has_key(state.client_states, client_id)
}

/// Get all connected client IDs
pub fn connected_clients(state: SequenceState) -> List(String) {
  dict.keys(state.client_states)
}
