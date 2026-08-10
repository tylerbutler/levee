# CLAUDE.md - Levee

Fluid Framework-compatible collaborative document service with an Elixir/Gleam server and TypeScript client packages.

## Quick Reference

```bash
# Using just (preferred)
just setup            # Install all dependencies (server + client)
just build            # Build everything
just test             # Run all tests
just server           # Start dev server (localhost:4000)
just iex              # Start with interactive shell

# Server only
just build-server     # Build Gleam + Elixir
just test-server      # Run server tests
just format-server    # Format server code

# Client only
just build-client     # Build TypeScript packages
just test-client      # Run client tests
just format-client    # Format client code
```

## Project Structure

```
levee/
├── server/                     # Elixir/Gleam server
│   ├── mix.exs                 # Elixir project config
│   ├── config/                 # Phoenix configuration
│   ├── lib/                    # Elixir source code
│   │   ├── levee/              # Core application
│   │   └── levee_web/          # Web layer (routes, channels)
│   ├── test/                   # Elixir tests
│   ├── priv/                   # Static assets, migrations
│   ├── levee_auth/             # Gleam auth library
│   └── levee_admin/            # Lustre admin UI
│   # Fluid protocol logic lives in the external `spillway` package
│   # (a dependency of floodgate), not an in-repo Gleam package
├── client/                     # TypeScript client packages
│   ├── package.json            # pnpm workspace root
│   ├── pnpm-workspace.yaml     # Workspace config
│   ├── tsconfig.json           # Root project references
│   ├── tsconfig.strict.json    # Shared strict config
│   ├── vitest.config.ts        # Shared test config
│   ├── biome.jsonc             # Formatting/linting config
│   └── packages/
│       ├── levee-driver/       # Phoenix Channels Fluid driver
│       ├── levee-client/       # High-level client API
│       ├── floodgate-client/   # Official Routerlicious integration for Floodgate
│       ├── floodgate-presence-tracker/ # Floodgate Presence example
│       ├── levee-example/      # DiceRoller example app
│       ├── levee-presence-tracker/  # Presence tracking example
│       ├── levee-todo-list/    # Collaborative todo-list example
│       └── sandbag/            # SvelteKit testing hub
├── justfile                    # Task runner (orchestrates both)
├── mise.toml                   # Tool versions
├── hk.pkl                      # Git hooks config
├── .gitignore                  # Ignore rules for both
├── .editorconfig               # Editor settings
├── CLAUDE.md                   # This file
├── AGENTS.md                   # Agent configurations
├── README.md                   # Project README
├── docs/                       # Documentation
├── .claude/                    # Claude Code config
├── .serena/                    # Serena config
└── .github/                    # GitHub Actions
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

### Client Package Dependency Graph
```
levee-presence-tracker → levee-client → levee-driver
levee-todo-list → levee-client → levee-driver
levee-example → levee-driver
floodgate-client → @fluidframework/routerlicious-driver
floodgate-presence-tracker → floodgate-client → @fluidframework/routerlicious-driver
```

## Server (`server/`)

### Core Application (`server/lib/levee/`)

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
| `storage/gleam_ets.ex` | Gleam ETS storage bridge (default backend) |
| `storage/ets.ex` | Legacy ETS storage (Elixir, fallback) |

### Web Layer (`server/lib/levee_web/`)

| File | Purpose |
|------|---------|
| `router.ex` | HTTP routes and WebSocket endpoint |
| `plugs/auth.ex` | JWT authentication plug, validates scopes |
| `channels/document_channel.ex` | WebSocket channel for real-time ops |
| `controllers/document_controller.ex` | Create/get documents REST API |
| `controllers/delta_controller.ex` | Get deltas/ops REST API |
| `controllers/git_controller.ex` | Git-like blob/tree/commit/ref APIs |
| `controllers/admin_controller.ex` | Admin UI SPA catch-all |

### Gleam Packages

- **levee_auth/** - JWT, password hashing, tenant/user management
- **levee_storage/** - Storage types and ETS backend (bravo for typed ETS access)
- **levee_admin/** - Lustre SPA for admin UI

The Fluid protocol logic (message types, sequencing, validation, signals,
nacks, schema generation) lives in the external **spillway** package, shared by
both the classic Levee path (`Levee.Protocol.Bridge`) and floodgate. It is
pulled in as a dependency of `floodgate`, so it compiles under
`floodgate/build/`.

### Gleam Testing (startest)

The Gleam packages use **startest** (not gleeunit) for tests.
- `should.*` → `expect.*` (e.g., `expect.to_equal`, `expect.to_be_ok`)
- **Gotcha:** `let assert Pattern = expr` inside startest tests wraps values in `Ok()` due to startest's rescue mechanism. Use `case` expressions for error variant destructuring instead of `let assert`.

### Running Server Commands

```bash
cd server && mix test                                          # All tests
cd server && mix test test/levee/documents/session_test.exs    # Single file
cd server && mix test test/levee/documents/session_test.exs:42 # Specific line
cd server && mix phx.server                                    # Dev server
```

## Client (`client/`)

### Package Manager
- **pnpm** (required, v10.24.0)
- Workspace protocol: internal deps use `workspace:^`

### Packages

| Package | Description |
|---------|-------------|
| `levee-driver` | Low-level Phoenix Channels Fluid driver for Levee |
| `levee-client` | High-level client wrapping the driver |
| `floodgate-client` | Floodgate client boundary using the official Routerlicious driver |
| `floodgate-presence-tracker` | Presence tracking example using Floodgate |
| `levee-example` | DiceRoller example using driver directly |
| `levee-presence-tracker` | Presence tracking example using client |
| `levee-todo-list` | Collaborative todo-list example using client |
| `sandbag` | SvelteKit testing hub for the examples |

**Client compatibility strategy:** [ADR-004](docs/adr/004-coexisting-client-stacks.md) is the current source of truth. In summary:

- Levee and Floodgate are independent supported server stacks
- `levee-client` and `levee-driver` remain the Phoenix Channels client stack
- `floodgate-client` uses the official Routerlicious driver
- Shared protocol libraries and conformance fixtures are reused without merging the client packages

**Floodgate is dual-mode** ([ADR-008](docs/adr/008-floodgate-phoenix-endpoint.md)): one
Floodgate process serves both wire protocols from the same beryl coordinator,
channels, session, and storage —

- `/socket.io/` — official Fluid/Routerlicious drivers (`floodgate-client`)
- `/socket/websocket` — Phoenix Channels (`levee-driver`/`levee-client`), wire-compatible
  with the Elixir server's `DocumentChannel`

so Floodgate is a drop-in replacement for the Elixir server for existing
`levee-client` apps. Clients of both kinds can collaborate on one document.
Verify with `just test-floodgate-dual-mode`, which runs both conformance suites
plus cross-mode tests against a single server process.

**Floodgate speaks server-backed presence** (`presence_v1`), on both socket
endpoints, on top of beryl's presence registry — advertised as
`supportedFeatures: {presence_v1: true}` in `connect_document_success`, driven by
`joinPresence`/`updatePresence`/`leavePresence`, and answered with Phoenix-shaped
`presence_state`/`presence_diff`/`presence_error`. `src/floodgate/presence_worker.gleam`
owns the beryl handle: beryl's presence calls are 5-second `process.call`s that
panic, and channel callbacks run inside the coordinator, so they cannot be made
there. Identity (`key` from the token's user id, `client_id` from the
server-assigned client id) is derived server-side and a client naming one is
rejected. Cross-node replication enables itself only on a distributed node. See
`server/floodgate/README.md`'s Presence section for the wire contract. Levee
(Elixir) does not advertise the capability, and clients fall back cleanly.

**Floodgate is multi-tenant**, dynamically, not just via the one
`FLOODGATE_TENANT_ID`/`FLOODGATE_JWT_SECRET` pair: tenants are created,
listed, shown, and deleted through an admin API
(`GET/POST /api/tenants`, `GET/DELETE /api/tenants/:id`,
`POST /api/tenants/:id/secrets/:slot`) gated by a Floodgate admin session or
`FLOODGATE_ADMIN_KEY`, with response shapes matching what
`server/levee_admin`'s Lustre UI already expects.
Each tenant has two rotating JWT secret slots — verification tries both, minting
uses slot 1 — and tenants persist on whichever storage backend documents use
(`FLOODGATE_STORAGE_BACKEND`). `FLOODGATE_TENANT_ID`/`FLOODGATE_JWT_SECRET`
still seed/ensure that one tenant at boot, so existing single-tenant
deployments, clients, tests, docker, and parity suites are unaffected. See
`server/floodgate/README.md`'s Multi-tenancy section for the full contract.
Floodgate serves the shared Lustre UI itself and uses Vestibule for GitHub
OAuth; the implementation and container remain Gleam/BEAM-only.

**Drop-in parity check:** `just test-levee-suite-vs-floodgate` runs Levee's
*unmodified* integration suites (`levee-driver`, `levee-client`,
`levee-example`) against a containerised Floodgate, repointed only via
`LEVEE_HTTP_URL`/`LEVEE_SOCKET_URL`/`LEVEE_TENANT_KEY`. Nothing in those suites
is Floodgate-aware, so a failure there is a real behavioural difference between
the servers. [ADR-009](docs/adr/009-floodgate-standalone-repo.md) records the
parity surface, the known remaining gaps, and what blocks extracting Floodgate
into its own repository.

Floodgate has its own container image (`server/floodgate/Dockerfile`,
`docker-compose.yml`) built from a `gleam export erlang-shipment` — no Elixir or
Mix — plus its own `README.md`, `justfile`, and CI workflow, so it is ready to
move out as a directory.

### Client Commands

```bash
cd client && pnpm install           # Install deps
cd client && pnpm build             # Build all packages (tsc --build)
cd client && pnpm test              # Run all tests (vitest)
cd client && pnpm format            # Format with Biome
cd client && pnpm lint              # Lint with Biome
```

### TypeScript Configuration
- Packages extend `client/tsconfig.strict.json` → `client/tsconfig.base.json` → `@tsconfig/node18`
- Tabs for indentation (Biome)
- Vitest for testing with shared base config

## Code Generation

Generate protocol schema from Gleam types and copy to client:
```bash
just generate-schema-ts
```

## Common Workflows

### Adding a New API Endpoint
1. Add route to `server/lib/levee_web/router.ex`
2. Create/update controller in `server/lib/levee_web/controllers/`
3. Add tests in `server/test/levee_web/controllers/`
4. Run `just test-elixir` to verify

### Modifying Gleam Protocol
1. Edit protocol logic in the external `spillway` package (repo:
   tylerbutler/spillway); bump the ref in `server/floodgate/gleam.toml`
2. Run `just build-gleam` to compile
3. Update `server/lib/levee/protocol/bridge.ex` if Elixir interop changes
4. Run `just test` to verify both Gleam and Elixir tests
5. If schema types changed, run `just generate-schema-ts`

### Rebuilding After Gleam Changes
```bash
just build-gleam                    # Compile Gleam
cd server && mix compile --force    # Reload BEAM modules
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
GET    /repos/:tenant_id/commits          Commit history (?sha=&count=), for
                                          the Routerlicious driver's getVersions
GET    /refs/:tenant_id                   List refs
GET    /refs/:tenant_id/*path             Get ref
PATCH  /refs/:tenant_id/*path             Update ref

# WebSocket
WS     /socket/websocket                  Real-time channel
       Topic: "document:{tenant_id}:{document_id}"

# Admin UI (Lustre SPA)
GET    /admin                             Admin login page
GET    /admin/*path                       SPA catch-all
```

## Gleam/Elixir Interoperability

### Module Naming

| Gleam File | Erlang/Elixir Module |
|------------|---------------------|
| `spillway.gleam` | `:spillway` |
| `sequencing.gleam` | `:spillway@sequencing` |
| `message.gleam` | `:spillway@message` |

### Type Conversions

| Gleam | Elixir |
|-------|--------|
| `String` | binary `""` |
| `Int` | integer |
| `List(a)` | list `[]` |
| `Dict(k, v)` | map `%{}` |
| `Option(a)` | `nil` or value |
| `Result(ok, err)` | `{:ok, val}` or `{:error, val}` |

## Environment Variables

| Variable | Purpose |
|----------|---------|
| `LEVEE_TENANT_ID` | Auto-register tenant at startup |
| `LEVEE_TENANT_KEY` | Secret for auto-registered tenant |
| `LEVEE_DISABLE_AUTO_MEMBERSHIP` | Set `true` to disable auto-adding users to all tenants on login |
| `SECRET_KEY_BASE` | Phoenix secret (production) |
| `PHX_HOST` | Host for production |
| `PORT` | HTTP port (default: 4000) |

Floodgate (Gleam server) reads its own set:

| Variable | Purpose |
|----------|---------|
| `FLOODGATE_TENANT_ID` | Id of the startup tenant, seeded from `FLOODGATE_JWT_SECRET` at boot if not already registered (default: `fluid`) |
| `FLOODGATE_JWT_SECRET` | Required; the startup tenant's first secret slot |
| `FLOODGATE_GITHUB_CLIENT_ID` / `FLOODGATE_GITHUB_CLIENT_SECRET` | GitHub OAuth App credentials for the admin UI |
| `FLOODGATE_ADMIN_GITHUB_USERS` | Comma-separated GitHub usernames allowed to administer Floodgate; unset denies OAuth login |
| `FLOODGATE_ADMIN_KEY` | Bearer key for the tenant management API (`GET/POST /api/tenants`, etc.); unset disables that API |
| `PORT` / `FLOODGATE_PORT` | Listen port (default: `3000`; `PORT` wins) |
| `FLOODGATE_BIND` | Listen interface (default: `localhost`); containers need `0.0.0.0` |
| `FLOODGATE_TOKEN_MINT_SECRET` | Enables the token-mint endpoint |
| `FLOODGATE_STORAGE_BACKEND` | `ets`/`shelf` (persistent, default) or `memory` — also where tenants persist |
| `FLOODGATE_DATA_DIR` | Shelf DETS directory (default: `priv/floodgate_data`). **One DETS file per document** under `documents/t<hex tenant>/d<hex document id>.dets` — see [ADR-010](docs/adr/010-per-document-storage.md); refs, tenants and admin data stay in shared files |
| `FLOODGATE_DOC_IDLE_MS` | How long an untouched document stays in memory (default 300000). Drops *both* its cached sequence state and its open DETS file; only ever a cache drop, since writes are already on disk. `0` disables |
| `FLOODGATE_MAX_OPEN_DOCUMENTS` | Document files open at once (default 1024); at the cap the least recently used is closed. `0` disables |
| `FLOODGATE_PUBLIC_URL` | Externally reachable base URL |
| `FLOODGATE_ALLOWED_ORIGINS` | Origin allow-list for **both** socket endpoints (comma-separated, or `*` to disable checking). Defaults to same-origin, which rejects cross-origin browser upgrades; clients sending no `Origin`, including the official Fluid drivers, are always admitted |
| `FLOODGATE_MAX_FRAME_BYTES` | Inbound frame ceiling (default 16 MiB). Also the `maxMessageSize` advertised in IConnected and the Engine.IO handshake's `maxPayload` — one value, so the three cannot drift |
| `FLOODGATE_MAX_CONNECTIONS_PER_IP` / `FLOODGATE_MAX_CONNECTIONS` | Concurrent socket ceilings, per peer address (default 256) and node-wide (default 4096) |
| `FLOODGATE_MESSAGE_RATE` / `_BURST`, `FLOODGATE_JOIN_RATE` / `_BURST` | Per-socket inbound frame and join rate limits (defaults 1000/2000, 100/200) |
| `FLOODGATE_HEARTBEAT_INTERVAL_MS` / `FLOODGATE_HEARTBEAT_TIMEOUT_MS` | Suggested client ping cadence and the server-side staleness window (defaults 30000 / 60000). The timeout drives the coordinator sweep that evicts a socket which stopped heartbeating — and, via the registered closer, actually closes it, so its stale RSN stops pinning the document's MSN. beryl derives its check interval as `timeout / 2`, so the timeout must be at least 2 |

Set any limit to `0` to disable it. Both socket endpoints now share the same guards —
origin policy, connection ceilings, rate limits, frame cap, and coordinator-initiated
close. Historically only the Phoenix endpoint had them, because `beryl_mist` applies them
and `floodgate/socketio_transport.gleam` is separate code; any new guard added to
`beryl_mist` should be checked against that file.

## Client Release Pipeline

### Changie (Changelog Management)
- Config: `client/.changie.yaml` (project mode with `levee-driver`, `levee-client`, and `floodgate-client`)
- Fragments go in `client/.changes/unreleased/` (root), NOT per-project subdirectories
- Each fragment YAML needs a `project` field to route to the correct package
- `changie` CLI is NOT in `mise.toml` — only available in CI via `miniscruff/changie-action`

### Release Workflow
1. Push to main → `client-changie-release.yml` creates/updates a release PR (label: `release:client`)
2. Merge release PR → `auto-tag.yml` pushes git tags, dispatches `Client npm Publish`
3. `client-release.yml` publishes to npm, then creates GitHub releases

### Reusable Actions (`tylerbutler/actions`)
- `changie-release` — batch changie entries, create release PR
- `changie-auto-tag` — create git tags from changie versions
- `changie-check` — detect fragments in PRs, render preview (supports `projects` input)

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
| `gleam-sync` | Rebuild Gleam protocol and reload Elixir modules |
