# CLAUDE.md - Levee

Fluid Framework-compatible collaborative document service with a pure Gleam server and TypeScript client packages.

## Quick Reference

```bash
just setup            # Install server + client dependencies
just build            # Build everything
just test             # Run all tests
just server           # Start Gleam server on localhost:4000

just build-server     # Build Gleam Erlang packages + admin JS
just test-server      # Run Gleam server package tests
just format-server    # Format Gleam server code

just build-client     # Build TypeScript packages
just test-client      # Run client tests
just format-client    # Format client code
```

## Project Structure

```
levee/
├── server/                     # Gleam server workspace
│   ├── levee_protocol/         # Protocol message types, sequencing, validation, schema generation
│   ├── levee_auth/             # JWT, password hashing, tenant/user/session management
│   ├── levee_storage/          # ETS/PostgreSQL storage backends
│   ├── levee_oauth/            # OAuth config and state store
│   ├── levee_documents/        # Document session actors and registry
│   ├── levee_server/           # Mist/Wisp HTTP server + Beryl channels
│   ├── levee_admin/            # Lustre admin UI (JavaScript target)
│   └── priv/                   # Static assets and data
├── client/                     # TypeScript client packages
├── docs/                       # Documentation
├── justfile                    # Task runner
└── mise.toml                   # Tool versions
```

## Architecture Overview

Levee provides real-time collaborative editing with:
- **Multi-tenant isolation** — data keyed by `{tenant_id, document_id}`
- **JWT authentication** — tenant-specific signing keys
- **Gleam OTP actors** — document sessions, registries, and supervision
- **ETS/PostgreSQL storage** — Gleam storage package with pluggable backends
- **Phoenix Channels-compatible wire protocol** — served by Gleam/Beryl over Mist

Request flow:

```
Client → Mist/Wisp router or Beryl channel → Gleam auth middleware → Document actors → Storage
```

Client package dependency graph:

```
levee-presence-tracker → levee-client → levee-driver
levee-example → levee-driver
```

## Server Packages

| Package | Purpose |
|---|---|
| `levee_server` | HTTP routes, WebSocket channels, static/admin serving, app boot |
| `levee_documents` | Document session actor, registry, supervisor, tenant secrets bridge |
| `levee_storage` | Storage types and ETS/PostgreSQL implementations |
| `levee_auth` | Users, tenants, sessions, JWT, scopes, password hashing |
| `levee_oauth` | OAuth provider config/state support |
| `levee_protocol` | Fluid protocol types, sequencing, validation, schema CLI |
| `levee_admin` | Lustre SPA admin UI, JavaScript target |

## Running Server Commands

```bash
cd server/levee_server && gleam run              # Dev server
cd server/levee_server && gleam test             # Server tests
cd server/levee_storage && gleam test            # Storage tests
```

## Client

- Package manager: pnpm 10.24.0
- TypeScript project references
- Biome formatting/linting
- Vitest tests

```bash
cd client && pnpm install
cd client && pnpm build
cd client && pnpm test
cd client && pnpm format
cd client && pnpm lint
```

## Code Generation

Generate protocol schema from Gleam types and copy to the client driver:

```bash
just generate-schema-ts
```

This runs `cd server/levee_protocol && gleam run -m schema_cli` and writes `server/priv/protocol-schema.json`.

## Common Workflows

### Adding a REST Endpoint
1. Add/update route handling in `server/levee_server/src/levee_server/routes/`.
2. Add auth/scope checks through existing route helpers.
3. Add tests under `server/levee_server/test/`.
4. Run `cd server/levee_server && gleam test`.

### Modifying Protocol Types
1. Edit `server/levee_protocol/src/`.
2. Run `cd server/levee_protocol && gleam test`.
3. If schema changed, run `just generate-schema-ts`.
4. Run affected server/client tests.

### Rebuilding After Gleam Changes

```bash
just build-server
just test-server
```

## API Routes

All authenticated routes require Bearer tokens with appropriate scopes.

```
POST   /documents/:tenant_id
GET    /documents/:tenant_id/:id
GET    /documents/:tenant_id/session/:id
GET    /deltas/:tenant_id/:id
GET    /repos/:tenant_id/git/blobs/:sha
POST   /repos/:tenant_id/git/blobs
GET    /repos/:tenant_id/git/trees/:sha
POST   /repos/:tenant_id/git/trees
GET    /repos/:tenant_id/git/commits/:sha
POST   /repos/:tenant_id/git/commits
GET    /refs/:tenant_id
GET    /refs/:tenant_id/*path
PATCH  /refs/:tenant_id/*path
WS     /socket/websocket   topic: document:{tenant_id}:{document_id}
GET    /admin/*path
```

## Environment Variables

| Variable | Purpose |
|---|---|
| `PORT` | HTTP port (default: 4000) |
| `LEVEE_TENANT_ID` | Auto-register tenant at startup |
| `LEVEE_TENANT_KEY` | Secret for auto-registered tenant |
| `LEVEE_DISABLE_AUTO_MEMBERSHIP` | Disable auto-adding users to all tenants on login |
| `DATABASE_URL` | PostgreSQL storage backend URL |
| `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET`, `GITHUB_REDIRECT_URI` | GitHub OAuth config |

## Gleam/Erlang FFI Kept Intentionally

- `levee_auth/src/password_ffi.erl` — PBKDF2/password hashing helper.
- `levee_auth/src/tenant_secrets_ffi.erl` — env lookup and tenant-id generation.
- `levee_storage/src/storage_ffi_helpers.erl` — JSON/timestamp/ETS helper functions.
- `levee_server/src/levee_server_ffi.erl` — server runtime helpers.

## Release Pipeline

Server releases use Changie config in `server/.changie.yaml`, GitHub Actions, and Docker images built from the Gleam server shipment.
