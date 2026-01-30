# Operation Ordering and Sequence Number Management

This document explains how Levee ensures correct sequence number assignment and proper ordering of collaborative operations.

## Sequence Number Components

The service tracks four sequence number components:

| Abbrev | Name | Purpose |
|--------|------|---------|
| **SN** | Sequence Number | Server-assigned global order |
| **CSN** | Client Sequence Number | Per-client monotonic counter |
| **RSN** | Reference Sequence Number | Client's last-seen SN when submitting |
| **MSN** | Minimum Sequence Number | Minimum RSN across all clients |

## How Correct Assignment is Ensured

### 1. Single-Writer Per Document via GenServer

Each document has exactly one GenServer process. All operations for a document flow through this single process, which serializes access to the sequence state. This eliminates race conditions - the GenServer's mailbox naturally orders incoming requests.

```elixir
defmodule Levee.Documents.Session do
  use GenServer

  defstruct [
    :document_id,
    :sequence_state,      # Gleam SequenceState
    :connected_clients,
    :operation_history,   # Last 1000 ops for catch-up
    :pending_summaries
  ]

  def handle_call({:submit_op, client_id, op}, _from, state) do
    # Calls Gleam sequencing logic
    case Protocol.Bridge.assign_sequence_number(...) do
      {:ok, new_state, seq_num} -> ...
      {:error, reason} -> ...
    end
  end
end
```

### 2. Gleam Validation Rules

The Gleam sequencing module enforces these invariants:

- **CSN must be monotonically increasing per client** - prevents duplicate or out-of-order client operations
- **RSN cannot be from the future** - no sequence number inflation attacks
- **Client must be known to session** - only authenticated clients can submit operations

```gleam
fn assign_sequence_number(
  state: SequenceState,
  client_id: String,
  csn: Int,       // Client's sequence number
  rsn: Int,       // Reference sequence number
) -> Result(#(SequenceState, Int), SequenceError)
```

### 3. Type-Safe State Transitions

The Gleam `assign_sequence_number` function returns a `Result` type - either a new state with the assigned sequence number, or an error. Invalid operations are rejected via Nack messages rather than corrupting state.

## Request Buffering

There are two levels of buffering to ensure correct ordering:

### Client-Side Buffering

Operations submitted before the WebSocket connection completes are queued in the driver layer:

```
submit(op1)  ──┐
submit(op2)  ──┼──► Queue
submit(op3)  ──┘
                    │
    connect_document_success
                    │
                    ▼
              Flush queue to server
```

Once `connect_document_success` is received, the queue flushes in order. This prevents message loss during startup.

### Server-Side Ordering

The GenServer mailbox provides implicit ordering. When multiple clients submit operations concurrently, the BEAM VM delivers messages to the GenServer's mailbox in arrival order. The GenServer processes them one at a time via `handle_call`, assigning sequence numbers atomically.

The session also maintains an operation history (last 1000 ops) to allow clients that reconnect or join late to receive missed operations in the correct sequence order.

## Request Flow

```
Client                     Elixir                      Gleam
  │                          │                           │
  │ submitOp(op, csn, rsn)   │                           │
  │─────────────────────────>│                           │
  │                          │                           │
  │                   DocumentChannel                    │
  │                          │ validate token            │
  │                          │──────────────────────────>│
  │                          │<──────────────────────────│
  │                          │                           │
  │                     Session (GenServer)              │
  │                          │ assign_sequence_number    │
  │                          │──────────────────────────>│
  │                          │<──── {:ok, state, sn} ────│
  │                          │                           │
  │        op(sequenced)     │                           │
  │<─────────────────────────│                           │
```

## Summary

The design relies on:

1. **GenServer isolation** - one process per document serializes all writes
2. **Gleam's type system** - compile-time guarantees prevent invalid state transitions
3. **Client-side queuing** - prevents message loss during connection setup
4. **Server-side history** - enables catch-up for late joiners
