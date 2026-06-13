# Server Development Guide

The server is now Gleam-only. There is no Mix/Phoenix app under `server/`.

## Quick Start

```bash
# From repo root using just (preferred)
just setup-server     # Download Gleam dependencies
just build-server     # Build Erlang-target packages + admin JS
just server           # Start the server at localhost:4000

# Or directly
cd server/levee_server
gleam run
```

## Default Dev Tenant

The development server can auto-register a tenant from environment variables:

```bash
LEVEE_TENANT_ID=fluid LEVEE_TENANT_KEY=dev-tenant-secret-key just server
```

If unset, the server uses its built-in development defaults.

## Running Tests

```bash
just test-server      # All server Gleam tests
just test-gleam       # Same server package test suite

cd server/levee_server && gleam test
cd server/levee_auth && gleam test
cd server/levee_storage && gleam test
cd server/levee_documents && gleam test
cd server/levee_protocol && gleam test
```

## Package Layout

- `levee_server/` — runtime entrypoint, HTTP routes, WebSocket channels, static assets
- `levee_documents/` — document actors, registry, supervisors
- `levee_storage/` — ETS/PostgreSQL storage
- `levee_auth/` — auth, tenants, users, sessions, JWTs
- `levee_oauth/` — OAuth provider/state support
- `levee_protocol/` — Fluid protocol and schema generation
- `levee_admin/` — Lustre admin UI (JavaScript target)

## Protocol Schema

```bash
just generate-schema-ts
```

This runs `cd server/levee_protocol && gleam run -m schema_cli` and copies the schema into the TypeScript driver.

## Running Client Tests Against This Server

```bash
# Terminal 1
just server

# Terminal 2
cd client/packages/levee-driver
vitest run test/integration
```

Client packages also include Docker Compose files for running the server from a published image or building from local source.

## Docker

```bash
cd server
docker build -t levee:local .
docker run -p 4000:4000 \
  -e LEVEE_TENANT_ID=fluid \
  -e LEVEE_TENANT_KEY=dev-tenant-secret-key \
  levee:local
```
