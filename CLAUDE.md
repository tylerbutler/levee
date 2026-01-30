# CLAUDE.md - Levee

Fluid Framework-compatible collaborative document service written in Elixir/Gleam.

## Quick Reference

```bash
# Using just (preferred)
just setup            # Install all dependencies
just build            # Build Gleam + Elixir
just test             # Run all tests
just server           # Start dev server (localhost:4000)
just iex              # Start with interactive shell

# Using mix directly
mix deps.get          # Install dependencies
mix compile           # Compile project
mix test              # Run tests
mix phx.server        # Start dev server
iex -S mix phx.server # Start with interactive shell
```

## Architecture Overview

Levee provides real-time collaborative editing with:
- **Multi-tenant isolation** - All data keyed by `{tenant_id, document_id}`
- **JWT authentication** - Per-tenant signing keys
- **ETS storage** - In-memory storage (dev), pluggable backend
- **Gleam protocol** - Type-safe sequencing logic on BEAM

### Request Flow
```
Client → Phoenix Router → Auth Plug (JWT) → Controller/Channel → Session GenServer → Storage
```

## Project Structure

### Core Application (`lib/levee/`)

| File | Purpose |
|------|---------|
| `application.ex` | OTP supervision tree, starts all services |
| `auth/tenant_secrets.ex` | GenServer managing tenant registration and secrets |
| `auth/jwt.ex` | JWT signing/verification using tenant-specific keys |
| `documents/session.ex` | Per-document GenServer, handles ops, broadcasts to clients |
| `documents/registry.ex` | Registry for looking up sessions by `{tenant_id, doc_id}` |
| `documents/supervisor.ex` | DynamicSupervisor for document sessions |
| `protocol/bridge.ex` | Elixir ↔ Gleam interop for protocol logic |
| `storage/behaviour.ex` | Storage interface (behaviour) |
| `storage/ets.ex` | ETS-based storage implementation |

### Web Layer (`lib/levee_web/`)

| File | Purpose |
|------|---------|
| `router.ex` | HTTP routes and WebSocket endpoint |
| `plugs/auth.ex` | JWT authentication plug, validates scopes |
| `channels/document_channel.ex` | WebSocket channel for real-time ops |
| `channels/user_socket.ex` | Socket configuration |
| `controllers/document_controller.ex` | Create/get documents REST API |
| `controllers/delta_controller.ex` | Get deltas/ops REST API |
| `controllers/git_controller.ex` | Git-like blob/tree/commit/ref APIs |
| `controllers/health_controller.ex` | Health check endpoint |

### Gleam Protocol (`levee_protocol/src/`)

| File | Purpose |
|------|---------|
| `levee_protocol.gleam` | Main module, exports public API |
| `sequencing.gleam` | Operation sequencing, ref_seq/seq_num logic |
| `message.gleam` | Protocol message types and parsing |
| `signal.gleam` | Client signal types (join, leave, etc.) |
| `signals.gleam` | Signal handling and broadcast logic |
| `summary.gleam` | Summary/snapshot message handling |
| `nack.gleam` | Negative acknowledgment types |
| `types.gleam` | Core type definitions |
| `validation.gleam` | Message validation |
| `schema.gleam` | JSON schema generation |

### Configuration (`config/`)

| File | Purpose |
|------|---------|
| `config.exs` | Base configuration |
| `dev.exs` | Development settings (debug, code reload) |
| `test.exs` | Test settings |
| `prod.exs` | Production settings |
| `runtime.exs` | Runtime secrets from env vars |

### Tests (`test/`)

| File | Purpose |
|------|---------|
| `test_helper.exs` | Test setup, loads Gleam BEAM modules |
| `support/conn_case.ex` | HTTP test helpers |
| `support/channel_case.ex` | WebSocket test helpers |
| `levee/auth/*_test.exs` | Auth module tests |
| `levee/documents/*_test.exs` | Document session tests |
| `levee_web/channels/*_test.exs` | Channel tests |
| `levee_web/plugs/*_test.exs` | Auth plug tests |

## Common Workflows

### Adding a New API Endpoint

1. Add route to `lib/levee_web/router.ex` in appropriate pipeline
2. Create/update controller in `lib/levee_web/controllers/`
3. Add tests in `test/levee_web/controllers/`
4. Run `just test-elixir` to verify

### Modifying Gleam Protocol

1. Edit files in `levee_protocol/src/`
2. Run `just build-gleam` to compile
3. Update `lib/levee/protocol/bridge.ex` if Elixir interop changes
4. Run `just test` to verify both Gleam and Elixir tests

### Running Specific Tests

```bash
mix test test/levee/documents/session_test.exs       # Single file
mix test test/levee/documents/session_test.exs:42    # Specific line
mix test --only wip                                   # Tagged tests
mix test test/levee_web/                              # Directory
mix test --trace                                      # Verbose output
```

### Pre-Commit Checks

Before committing, run:
```bash
just check-format && just test
```

## Key Concepts

### Tenant System

Tenants are isolated organizational units. Each tenant:
- Has a unique `tenant_id` string
- Has its own JWT signing secret
- Contains completely isolated documents

**Registration:**
```elixir
# Register at runtime
TenantSecrets.register_tenant("my-tenant", "secret-key")

# Or via environment variables (loaded at startup)
LEVEE_TENANT_ID=my-tenant LEVEE_TENANT_KEY=secret-key mix phx.server

# Dev convenience (uses default dev secret)
TenantSecrets.register_dev_tenant("dev-tenant")
```

**No default tenants exist** - must be registered before use.

### JWT Authentication

Tokens are tenant-specific and document-specific:
```elixir
%{
  tenantId: "tenant-123",
  documentId: "doc-456",
  scopes: ["doc:read", "doc:write"],
  user: %{id: "user-789"},
  exp: expiration_timestamp
}
```

Generate test tokens:
```elixir
JWT.generate_test_token(tenant_id, document_id, user_id)
JWT.generate_read_only_token(tenant_id, document_id, user_id)
JWT.generate_full_access_token(tenant_id, document_id, user_id)
```

### Authorization Scopes

| Scope | Grants Access To |
|-------|-----------------|
| `doc:read` | Read document, subscribe to ops, get deltas |
| `doc:write` | Submit operations (`submitOp`) |
| `summary:read` | Read blobs, trees, commits, refs |
| `summary:write` | Write blobs, trees, commits, update refs |

### Storage Keys

All storage uses composite keys for tenant isolation:
- Documents: `{tenant_id, document_id}`
- Deltas: `{tenant_id, document_id, sequence_number}`
- Blobs/Trees/Commits: `{tenant_id, sha}`
- References: `{tenant_id, ref_path}`

### Document Sessions

Sessions are created on-demand when first client connects:
```elixir
# Lookup or start session
Session.start_or_get(tenant_id, document_id)

# Sessions track:
# - Current sequence number
# - Connected clients
# - Recent operations (for catch-up)
```

### Document Session Lifecycle

```
                  ┌─────────────────────────────────────┐
                  │                                     │
                  ▼                                     │
[Not Started] ──► [Initializing] ──► [Active] ──► [Idle/Timeout]
                  │                     │              │
                  │                     ▼              │
                  │               [Processing Op]      │
                  │                     │              │
                  │                     ▼              │
                  └─────────────── [Shutdown] ◄────────┘
```

Key state tracked: `%{seq_num: int, clients: MapSet, recent_ops: list}`

## API Routes

All authenticated routes require Bearer token with appropriate scopes.

```
# Documents
POST   /documents/:tenant_id              Create document
GET    /documents/:tenant_id/:id          Get document

# Operations
GET    /deltas/:tenant_id/:id             Get deltas

# Git-like storage
GET    /repos/:tenant_id/git/blobs/:sha   Get blob
POST   /repos/:tenant_id/git/blobs        Create blob
GET    /repos/:tenant_id/git/trees/:sha   Get tree
POST   /repos/:tenant_id/git/trees        Create tree
GET    /repos/:tenant_id/git/commits/:sha Get commit
POST   /repos/:tenant_id/git/commits      Create commit
GET    /refs/:tenant_id                   List refs
GET    /refs/:tenant_id/*path             Get ref
PATCH  /refs/:tenant_id/*path             Update ref

# WebSocket
WS     /socket/websocket                  Real-time channel
       Topic: "document:{tenant_id}:{document_id}"
```

### Route Pipelines

| Pipeline | Auth Level | Use For |
|----------|-----------|---------|
| `:api` | None | Public endpoints (health check) |
| `:authenticated` | Valid JWT | Basic auth, tenant validated |
| `:read_access` | JWT + `doc:read` | Read document data |
| `:write_access` | JWT + `doc:write` | Mutate document data |
| `:summary_access` | JWT + `summary:read` | Read git-like storage |
| `:summary_write_access` | JWT + `summary:write` | Write git-like storage |

## Error Handling Patterns

### Controller Errors

Use `:error` tuples with appropriate status codes:
```elixir
case result do
  {:ok, data} ->
    json(conn, data)
  {:error, :not_found} ->
    conn |> put_status(:not_found) |> json(%{error: "not_found"})
  {:error, :unauthorized} ->
    conn |> put_status(:forbidden) |> json(%{error: "forbidden"})
  {:error, :invalid_request} ->
    conn |> put_status(:bad_request) |> json(%{error: "invalid_request"})
end
```

### Common Status Codes

| Status | When to Use |
|--------|-------------|
| 200 | Success with body |
| 201 | Resource created |
| 204 | Success, no body |
| 400 | Invalid request data |
| 401 | Missing/invalid authentication |
| 403 | Valid auth but insufficient permissions |
| 404 | Resource not found |
| 409 | Conflict (e.g., ref update race) |

## Gleam/Elixir Interoperability

### Module Naming

Gleam modules compile to BEAM and are called via atoms:

| Gleam File | Erlang/Elixir Module |
|------------|---------------------|
| `levee_protocol.gleam` | `:levee_protocol` |
| `sequencing.gleam` | `:levee_protocol@sequencing` |
| `message.gleam` | `:levee_protocol@message` |

### Type Conversions

| Gleam | Elixir |
|-------|--------|
| `String` | binary `""` |
| `Int` | integer |
| `Float` | float |
| `Bool` | `true`/`false` |
| `List(a)` | list `[]` |
| `Dict(k, v)` | map `%{}` |
| `Option(a)` | `nil` or value |
| `Result(ok, err)` | `{:ok, val}` or `{:error, val}` |

### Calling Gleam from Elixir

```elixir
# Direct call
result = :levee_protocol.validate_message(msg)

# Pattern match on Result
case :levee_protocol@sequencing.assign_sequence(state, msg) do
  {:ok, {new_state, sequenced_msg}} -> # success
  {:error, :invalid_ref_seq} -> # specific error
  {:error, reason} -> # other errors
end
```

### Rebuilding After Gleam Changes

```bash
just build-gleam      # or: cd levee_protocol && gleam build --target erlang
mix compile --force   # Reload BEAM modules
```

## Testing Patterns

### Standard Test Setup

```elixir
@tenant_id "test-tenant"
@document_id "test-doc"

setup do
  TenantSecrets.register_tenant(@tenant_id, "test-secret-key")
  on_exit(fn -> TenantSecrets.unregister_tenant(@tenant_id) end)
  :ok
end
```

### HTTP Tests (ConnCase)

```elixir
test "returns document with valid token", %{conn: conn} do
  token = JWT.generate_test_token(@tenant_id, @document_id, "user-1")

  conn =
    conn
    |> put_req_header("authorization", "Bearer #{token}")
    |> get("/documents/#{@tenant_id}/#{@document_id}")

  assert json_response(conn, 200)
end
```

### Channel Tests (ChannelCase)

```elixir
test "connect_document with valid token", %{socket: socket} do
  token = JWT.generate_test_token(@tenant_id, @document_id, "user-1")

  ref = push(socket, "connect_document", %{"token" => token})
  assert_reply ref, :ok, %{"clientId" => _}
end
```

## Environment Variables

| Variable | Purpose |
|----------|---------|
| `LEVEE_TENANT_ID` | Auto-register tenant at startup |
| `LEVEE_TENANT_KEY` | Secret for auto-registered tenant |
| `SECRET_KEY_BASE` | Phoenix secret (production) |
| `PHX_HOST` | Host for production |
| `PORT` | HTTP port (default: 4000) |

## Claude Code Integration

### Available Agents

| Agent | Purpose |
|-------|---------|
| `security-reviewer` | Security audit for auth, scopes, tenant isolation |
| `test-helper` | Diagnose and fix test failures |
| `gleam-bridge` | Gleam ↔ Elixir interoperability issues |

### Available Skills

| Skill | Purpose |
|-------|---------|
| `api-doc` | Generate OpenAPI documentation from router |
| `new-endpoint` | Guide for adding new REST endpoints |
| `debug-channel` | Debug WebSocket channel issues |
