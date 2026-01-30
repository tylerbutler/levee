---
name: debug-channel
description: Debug WebSocket channel issues
---

# Debug WebSocket Channel

Guide for diagnosing and fixing WebSocket channel issues in Levee.

## Key Files

| File | Purpose |
|------|---------|
| `lib/levee_web/channels/document_channel.ex` | Channel message handlers |
| `lib/levee_web/channels/user_socket.ex` | Socket configuration |
| `lib/levee/documents/session.ex` | Document session GenServer |
| `test/levee_web/channels/document_channel_test.exs` | Channel tests |
| `test/support/channel_case.ex` | Test helpers |

## Channel Lifecycle

```
1. WebSocket Connect → UserSocket.connect/3
2. Join Topic → DocumentChannel.join/3 (validates but doesn't auth)
3. Connect Document → handle_in("connect_document") (authenticates)
4. Operations → handle_in("submitOp"), handle_in("submitSignal")
5. Leave/Disconnect → terminate/2
```

## Common Issues

### 1. Join Succeeds but Operations Fail

**Symptom**: Client joins channel but `submitOp` returns errors.

**Cause**: Channel join succeeds without auth; `connect_document` must be called first.

**Check**:
```elixir
# In document_channel.ex
def handle_in("submitOp", payload, socket) do
  case socket.assigns[:authenticated] do
    true -> # proceed
    _ -> {:reply, {:error, %{reason: "not_authenticated"}}, socket}
  end
end
```

### 2. Token Validation Failures

**Symptom**: `connect_document` returns auth error.

**Debug**:
```elixir
# Check token structure
JWT.verify_and_decode(tenant_id, token)
# Returns {:ok, claims} or {:error, reason}

# Common reasons:
# - :invalid_signature - wrong tenant secret
# - :token_expired - exp claim in past
# - :missing_claims - required fields missing
```

### 3. Scope Errors

**Symptom**: Operations rejected with scope error.

**Required Scopes**:
| Operation | Required Scope |
|-----------|---------------|
| Join channel | None |
| `connect_document` | `doc:read` |
| `submitOp` | `doc:write` |
| Receive broadcasts | `doc:read` |

**Check token scopes**:
```elixir
claims["scopes"]  # Should include required scope
```

### 4. Message Not Received

**Symptom**: Client doesn't receive broadcasts.

**Debug Steps**:
1. Verify client subscribed to correct topic
2. Check Session GenServer is broadcasting
3. Verify Phoenix.PubSub configuration

```elixir
# Topic format
"document:#{tenant_id}:#{document_id}"

# In Session, verify broadcast
Phoenix.PubSub.broadcast(Levee.PubSub, topic, message)
```

### 5. Session Not Found

**Symptom**: Operations fail with "session not found".

**Cause**: Session GenServer not started or crashed.

**Debug**:
```elixir
# Check if session exists
Levee.Documents.Registry.lookup(tenant_id, document_id)

# Start session manually
Levee.Documents.Session.start_or_get(tenant_id, document_id)
```

## Testing Channels

### Basic Test Setup

```elixir
defmodule LeveeWeb.DocumentChannelTest do
  use LeveeWeb.ChannelCase, async: true

  @tenant_id "test-tenant"
  @document_id "test-doc"

  setup do
    TenantSecrets.register_tenant(@tenant_id, "secret")
    on_exit(fn -> TenantSecrets.unregister_tenant(@tenant_id) end)

    {:ok, _, socket} =
      LeveeWeb.UserSocket
      |> socket("user_id", %{})
      |> subscribe_and_join(
          LeveeWeb.DocumentChannel,
          "document:#{@tenant_id}:#{@document_id}"
        )

    %{socket: socket}
  end
end
```

### Testing Authentication

```elixir
test "connect_document with valid token", %{socket: socket} do
  token = JWT.generate_test_token(@tenant_id, @document_id, "user-1")

  ref = push(socket, "connect_document", %{"token" => token})
  assert_reply ref, :ok, %{"clientId" => _}
end

test "connect_document with invalid token", %{socket: socket} do
  ref = push(socket, "connect_document", %{"token" => "invalid"})
  assert_reply ref, :error, %{"reason" => _}
end
```

### Testing Operations

```elixir
test "submitOp after authentication", %{socket: socket} do
  # First authenticate
  token = JWT.generate_full_access_token(@tenant_id, @document_id, "user-1")
  push(socket, "connect_document", %{"token" => token})
  assert_reply _, :ok, _

  # Then submit op
  op = %{"type" => "op", "contents" => [...]}
  ref = push(socket, "submitOp", op)
  assert_reply ref, :ok, _
end
```

## Debugging Commands

```bash
# Run channel tests with trace
mix test test/levee_web/channels/ --trace

# Run single test
mix test test/levee_web/channels/document_channel_test.exs:42

# Start server with debug logging
iex -S mix phx.server
# Then in IEx:
Logger.configure(level: :debug)
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
