# CLAUDE.md - Levee

Fluid Framework-compatible collaborative document service written in Elixir/Gleam.

## Quick Reference

```bash
mix deps.get          # Install dependencies
mix compile           # Compile project
mix test              # Run tests
mix phx.server        # Start dev server (localhost:4000)
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

## Testing Patterns

Standard test setup:
```elixir
@tenant_id "test-tenant"
@document_id "test-doc"

setup do
  TenantSecrets.register_tenant(@tenant_id, "test-secret-key")
  on_exit(fn -> TenantSecrets.unregister_tenant(@tenant_id) end)
  :ok
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
