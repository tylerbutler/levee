---
name: debug-channel
description: Debug WebSocket channel issues
---

# Debug WebSocket Channel

Guide for diagnosing and fixing WebSocket channel issues in Levee.

## Key Files

| File | Purpose |
|------|---------|
| `levee_channels/src/levee_channels/document_channel.gleam` | Channel message handlers (Beryl) |
| `levee_channels/src/levee_channels/runtime.gleam` | Channel runtime |
| `server/levee_web/src/levee_web/router.gleam` | WebSocket upgrade route |
| `server/lib/levee/documents/session.ex` | Document session GenServer |

## Channel Lifecycle

```
1. WebSocket Upgrade → Mist/Beryl accepts connection
2. Join Topic → document_channel join handler (validates topic format)
3. Connect Document → handle "connect_document" (authenticates via JWT)
4. Operations → handle "submitOp", "submitSignal"
5. Leave/Disconnect → channel cleanup
```

## Common Issues

### 1. Join Succeeds but Operations Fail

**Symptom**: Client joins channel but `submitOp` returns errors.

**Cause**: Channel join succeeds without auth; `connect_document` must be called first.

**Check**: The document_channel handler should verify authentication state before processing ops.

### 2. Token Validation Failures

**Symptom**: `connect_document` returns auth error.

**Debug**:
- Check token structure and expiration
- Verify tenant secret is registered
- Common reasons: wrong tenant secret, expired token, missing claims

### 3. Scope Errors

**Symptom**: Operations rejected with scope error.

**Required Scopes**:
| Operation | Required Scope |
|-----------|---------------|
| Join channel | None |
| `connect_document` | `doc:read` |
| `submitOp` | `doc:write` |
| Receive broadcasts | `doc:read` |

### 4. Session Not Found

**Symptom**: Operations fail with "session not found".

**Cause**: Session GenServer not started or crashed.

**Debug**: Check if the Elixir Registry and DynamicSupervisor are running (started by `start_elixir_session_infra` FFI call in levee_web main).

## Debugging Commands

```bash
# Run channel tests
cd levee_channels && gleam test

# Start server with debug logging
cd server/levee_web && gleam run
```

## Message Flow Diagram

```
Client                    Channel                  Session
  |                          |                        |
  |---join(topic)----------->|                        |
  |<--ok--------------------|                        |
  |                          |                        |
  |---connect_document------>|                        |
  |                          |--validate_token------->|
  |                          |<--{:ok, client_id}----|
  |<--ok, clientId----------|                        |
  |                          |                        |
  |---submitOp-------------->|                        |
  |                          |--process_op----------->|
  |                          |<--{:ok, sequenced}----|
  |<--ok--------------------|                        |
  |                          |                        |
  |                          |<--broadcast-----------|
  |<--op broadcast----------|                        |
```
