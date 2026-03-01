# Levee

Fluid Framework-compatible collaborative document service with an Elixir/Gleam server and TypeScript client packages.

## Prerequisites

Install tools using [mise](https://mise.jdx.dev/):

```bash
mise install    # Installs Elixir, Erlang, Gleam, Node.js, pnpm, just
```

Or install manually: Elixir 1.18+, Erlang/OTP 28+, Gleam 1.14+, Node.js 22+, pnpm 10.24+, [just](https://github.com/casey/just).

## Quick Start

```bash
just setup    # Install all dependencies (server + client)
just build    # Build everything
just test     # Run all tests
just server   # Start dev server at localhost:4000
```

## Project Structure

```
levee/
├── server/           # Elixir/Gleam server (Wisp/Mist)
├── client/           # TypeScript client packages (pnpm workspace)
│   └── packages/
│       ├── levee-driver/            # Low-level WebSocket Fluid driver
│       ├── levee-client/            # High-level client API (fluid-static style)
│       ├── levee-example/           # DiceRoller example app
│       └── levee-presence-tracker/  # Presence tracking example
├── justfile          # Task runner (orchestrates both)
└── mise.toml         # Tool versions
```

See [CLAUDE.md](CLAUDE.md) for detailed architecture documentation.

## Development

### Server

```bash
just server           # Start dev server (localhost:4000)
just iex              # Start with interactive Elixir shell
just test-server      # Run Gleam + Elixir tests
just build-server     # Build Gleam packages + Elixir
```

The server auto-registers a default dev tenant on startup. See [server/DEV.md](server/DEV.md) for server development details.

### Client

```bash
just build-client     # Build TypeScript packages (tsc --build)
just test-client      # Run unit tests (vitest)
just format-client    # Format with Biome
just lint-client      # Lint with Biome
```

## Testing

### Unit Tests (no server required)

```bash
just test-client    # Runs vitest — tests pure logic (URL resolution, tokens, etc.)
just test-server    # Runs mix test + gleam test
```

### Integration Tests (require running server)

Integration tests in client packages connect to a Levee server at `localhost:4000`. There are two ways to provide the server:

#### Option A: Native server (recommended for development)

```bash
# Terminal 1 — start the server
just server

# Terminal 2 — run integration tests
cd client/packages/levee-driver
pnpm test:integration    # Starts docker, runs tests, stops docker
# Or if server is already running:
vitest run test/integration
```

#### Option B: Docker (published image)

Each client package with integration tests includes a `docker-compose.yml` that pulls `ghcr.io/tylerbutler/levee:latest`:

```bash
cd client/packages/levee-driver

# Start server container
pnpm test:integration:up

# Run integration tests
vitest run test/integration

# View server logs
pnpm test:integration:logs

# Stop server
pnpm test:integration:down
```

#### Option C: Docker (local build)

Build and run the server from local source:

```bash
cd client/packages/levee-driver
docker compose -f docker-compose.yml -f docker-compose.local.yml up -d --wait --build

# Run tests, then stop
vitest run test/integration
docker compose down -v
```

The `docker-compose.local.yml` files build from the `server/` directory in this repo.

#### Integration test environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `LEVEE_HTTP_URL` | `http://localhost:4000` | HTTP API endpoint |
| `LEVEE_SOCKET_URL` | `ws://localhost:4000/socket` | WebSocket endpoint |
| `LEVEE_TENANT_KEY` | `dev-tenant-secret-key` | Tenant secret for token generation |

### E2E Tests (Playwright)

The `levee-presence-tracker` package has browser-based end-to-end tests using Playwright. These test the full stack: a Vite dev server serves the app, which connects to a running Levee server.

```bash
# 1. Start the Levee server (any method above)
just server

# 2. Run e2e tests
cd client/packages/levee-presence-tracker
pnpm test:e2e              # Headless
pnpm test:e2e:headed       # With visible browser
pnpm test:e2e:ui           # Interactive Playwright UI
```

The Playwright global setup automatically tries to start the server via Docker if it's not already running at `localhost:4000`. The tests start a Vite dev server on `localhost:3000` and run Chromium against it.

## Docker

The Dockerfile at `server/Dockerfile` builds a production image of the Levee server:

```bash
cd server
docker build -t levee:local .
docker run -p 4000:4000 \
  -e SECRET_KEY_BASE=$(openssl rand -base64 64) \
  -e LEVEE_TENANT_ID=fluid \
  -e LEVEE_TENANT_KEY=dev-tenant-secret-key \
  levee:local
```

A pre-built image is available at `ghcr.io/tylerbutler/levee:latest`.

## Code Generation

Generate protocol schema from Gleam types and copy to the client driver:

```bash
just generate-schema-ts
```
