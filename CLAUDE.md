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
│   ├── levee_protocol/         # Gleam protocol types
│   ├── levee_auth/             # Gleam auth library
│   └── levee_admin/            # Lustre admin UI
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
│       ├── levee-example/      # DiceRoller example app
│       └── levee-presence-tracker/  # Presence tracking example
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
levee-example → levee-driver
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

- **levee_protocol/** - Protocol message types, sequencing, validation, schema generation
- **levee_auth/** - JWT, password hashing, tenant/user management
- **levee_storage/** - Storage types and ETS backend (bravo for typed ETS access)
- **levee_admin/** - Lustre SPA for admin UI

### Gleam Testing (startest)

levee_protocol uses **startest** (not gleeunit) for tests.
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
| `levee-driver` | Low-level Phoenix Channels Fluid Framework driver |
| `levee-client` | High-level client wrapping the driver |
| `levee-example` | DiceRoller example using driver directly |
| `levee-presence-tracker` | Presence tracking example using client |

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
1. Edit files in `server/levee_protocol/src/`
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
| `levee_protocol.gleam` | `:levee_protocol` |
| `sequencing.gleam` | `:levee_protocol@sequencing` |
| `message.gleam` | `:levee_protocol@message` |

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
| `SECRET_KEY_BASE` | Phoenix secret (production) |
| `PHX_HOST` | Host for production |
| `PORT` | HTTP port (default: 4000) |

## Client Release Pipeline

### Changie (Changelog Management)
- Config: `client/.changie.yaml` (project mode with `levee-driver` and `levee-client`)
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
