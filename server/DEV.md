# Server Development Guide

## Quick Start

```bash
# From repo root using just (preferred)
just setup-server     # Install Gleam + Elixir dependencies
just build-server     # Build Gleam packages + Elixir
just server           # Start dev server at localhost:4000

# Or directly
cd server/levee_web
gleam run
```

## Default Dev Tenant

In development and test environments, a default tenant is automatically registered at startup:

| Property | Value |
|----------|-------|
| Tenant ID | `dev-tenant` |
| Secret | `levee-dev-secret-change-in-production` |

This allows immediate testing without manual tenant setup.

### Generate a JWT for the dev tenant

```elixir
# In iex -S mix
Levee.Auth.JWT.generate_test_token("dev-tenant", "my-doc", "user-1")
```

### Register additional tenants

```elixir
Levee.Auth.TenantSecrets.register_tenant("my-tenant", "my-secret-key")
```

Or via environment variables (loaded at startup):
```bash
cd server/levee_web
LEVEE_TENANT_ID=my-tenant LEVEE_TENANT_KEY=my-secret-key gleam run
```

## Running Tests

```bash
# From repo root
just test-server               # All server tests (Gleam + Elixir)
just test-elixir               # Elixir tests only
just test-gleam                # Gleam tests only

# Or directly from server/
cd server
mix test                       # All Elixir tests
mix test --only wip            # Tests tagged @tag :wip
mix test test/levee/documents/session_test.exs      # Single file
mix test test/levee/documents/session_test.exs:42   # Specific line
```

## Gleam Protocol

The `levee_protocol/`, `levee_auth/`, and `levee_admin/` directories contain Gleam packages that compile to BEAM.

After modifying Gleam files:

```bash
# From repo root (preferred)
just build-gleam
cd server && mix compile --force    # Reload BEAM modules

# Or directly
cd server/levee_protocol && gleam build
cd server && mix compile --force
```

## Running Client Tests Against This Server

Client integration tests and e2e tests need a running server. The simplest approach during development:

```bash
# Terminal 1 — start the server
just server

# Terminal 2 — run client integration tests
cd client/packages/levee-driver
vitest run test/integration

# Or run e2e tests (levee-presence-tracker)
cd client/packages/levee-presence-tracker
pnpm test:e2e
```

Client packages also include Docker Compose files for running the server from a published image or building from local source. See the [root README](../README.md#testing) for all options.

## Docker

The Dockerfile at `server/Dockerfile` builds a production image:

```bash
cd server
docker build -t levee:local .
docker run -p 4000:4000 \
  -e SECRET_KEY_BASE=$(openssl rand -base64 64) \
  -e LEVEE_TENANT_ID=fluid \
  -e LEVEE_TENANT_KEY=dev-tenant-secret-key \
  levee:local
```

Client packages have `docker-compose.local.yml` files that build from this directory automatically.
