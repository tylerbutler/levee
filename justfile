# Levee - Collaborative document service (server + client)

# === ALIASES ===
alias b := build
alias t := test
alias f := format
alias l := lint
alias c := clean

# Default recipe
default:
    @just --list

# === BUILD ===

# Build everything (server + client)
build: build-server build-client build-sandbag

# Build server (Gleam + admin + Elixir)
build-server: build-gleam build-admin build-elixir

# Build Gleam packages
build-gleam:
    cd server/levee_auth && gleam build --target erlang
    cd server/levee_storage && gleam build --target erlang
    cd server/levee_oauth && gleam build --target erlang
    cd server/levee_bridge && gleam build --target erlang
    cd server/levee_admin && gleam build --target javascript
    cd server/floodgate && gleam build --target erlang

# Build admin UI and copy to priv/static/admin
build-admin: build-gleam
    mkdir -p server/priv/static/admin
    cp -r server/levee_admin/build/dev/javascript/* server/priv/static/admin/
    cp server/levee_admin/index.html server/priv/static/admin/

# Build Elixir application
build-elixir: build-gleam
    cd server && mix compile

# Build client (TypeScript)
build-client:
    cd client && pnpm install && pnpm build

# Build Sandbag testing hub and copy to priv/static/sandbag
build-sandbag:
    cd client/packages/sandbag && pnpm build
    mkdir -p server/priv/static/sandbag
    cp -r client/packages/sandbag/build/* server/priv/static/sandbag/

# === TESTING ===

# Run all tests (server + client)
test: test-server test-client

# Run all tests including PostgreSQL backend
test-all: test-server test-client test-pg

# Run all server tests
test-server: test-gleam test-elixir

# Run Gleam tests
test-gleam:
    cd server/levee_auth && gleam test
    cd server/levee_oauth && gleam test
    cd server/levee_admin && gleam test
    cd server/floodgate && gleam test

# Run Elixir tests
test-elixir:
    cd server && mix test

# Run client tests
test-client:
    cd client && pnpm install && pnpm test

# Run client integration tests (starts Docker server, runs tests, stops server)
test-integration:
    cd client && pnpm test:integration

# Start integration test server
test-integration-up:
    cd client && pnpm test:integration:up

# Stop integration test server
test-integration-down:
    cd client && pnpm test:integration:down

# Run integration tests (assumes server already running)
test-integration-run:
    cd client && pnpm test:integration:run

# Drop-in check: run the *unmodified* Levee integration suites — levee-driver,
# levee-client, levee-example — against Floodgate instead of the Elixir server.
# Nothing about those suites is Floodgate-aware; they are simply repointed via
# LEVEE_HTTP_URL/LEVEE_SOCKET_URL/LEVEE_TENANT_KEY. Any failure here is a real
# behavioural difference between the two servers.
#
# Compare against the same suites on Levee with `just test-integration`.
test-levee-suite-vs-floodgate:
    cd server/floodgate && docker compose up -d --wait --build
    cd client && LEVEE_HTTP_URL=http://localhost:3000 \
        LEVEE_SOCKET_URL=ws://localhost:3000/socket \
        LEVEE_TENANT_KEY=dev-tenant-secret-key \
        pnpm vitest run integration; \
        result=$?; \
        cd ../server/floodgate && docker compose down -v; \
        exit $result

# Same drop-in check against an already-running Floodgate (e.g. `just floodgate-server`).
test-levee-suite-vs-floodgate-run:
    cd client && LEVEE_HTTP_URL=http://localhost:3000 \
        LEVEE_SOCKET_URL=ws://localhost:3000/socket \
        LEVEE_TENANT_KEY=${FLOODGATE_JWT_SECRET:-dev-tenant-secret-key} \
        pnpm vitest run integration

# Start/stop the containerised Floodgate used by the drop-in check.
floodgate-up:
    cd server/floodgate && docker compose up -d --wait --build

floodgate-down:
    cd server/floodgate && docker compose down -v

# Run Routerlicious driver compatibility contract against a running Floodgate server.
# This is the north-star conformance suite for the Floodgate-first client
# strategy (see docs/adr/002-client-compatibility-strategy.md): the official
# Routerlicious driver becomes the primary client once this suite is green.
test-floodgate-routerlicious:
    cd client && pnpm test:floodgate-routerlicious

# Run both wire protocols against ONE Floodgate process (ADR-008 dual mode):
# the Routerlicious driver over Socket.IO and the full levee-driver over the
# Phoenix endpoint, including cross-mode collaboration on a shared document.
# Starts the server, waits for readiness, runs both suites, then stops it.
test-floodgate-dual-mode:
    #!/usr/bin/env bash
    set -euo pipefail

    export FLOODGATE_JWT_SECRET=floodgate-routerlicious-compat-secret
    export FLOODGATE_TOKEN_MINT_SECRET=floodgate-routerlicious-mint-secret
    export FLOODGATE_STORAGE_BACKEND=memory

    server_pid=""
    cleanup() {
        # Kill the entire process group to terminate BEAM descendants.
        [ -n "$server_pid" ] && kill -- "-$server_pid" 2>/dev/null || true
    }
    trap cleanup EXIT INT TERM

    # setsid: new session/PGID = $server_pid so kill -- -$server_pid reaches BEAM.
    scripts/setsid-portable bash -c 'cd server/floodgate && gleam run' &
    server_pid=$!

    sleep 0.5
    if ! kill -0 "$server_pid" 2>/dev/null; then
        echo "ERROR: Floodgate server process exited immediately." >&2
        exit 1
    fi

    echo "Waiting for Floodgate server to be ready..."
    ready=false
    for i in $(seq 1 30); do
        code=$(curl --max-time 1 -s -o /dev/null -w "%{http_code}" \
            -X POST http://localhost:3000/api/tenants/fluid/token-mint \
            -H "Authorization: Bearer $FLOODGATE_TOKEN_MINT_SECRET" \
            -H "Content-Type: application/json" \
            -d '{"documentId":""}' \
            2>/dev/null) || code="000"
        if [ "$code" = "200" ]; then
            echo "Floodgate server ready (HTTP 200)."
            ready=true
            break
        fi
        echo "  waiting... ($i/30)"
        sleep 1
    done
    if [ "$ready" = "false" ]; then
        echo "ERROR: Floodgate server not ready after 30s." >&2
        exit 1
    fi

    cd client
    echo "=== Socket.IO endpoint (Routerlicious driver) ==="
    pnpm test:floodgate-routerlicious
    echo "=== Phoenix endpoint (levee-driver) + cross-mode ==="
    pnpm test:floodgate-phoenix

# Check standalone Floodgate release readiness against a running direct target.
# Levee remains an independent supported stack per ADR-004.
check-floodgate-readiness:
    cd client && pnpm check:floodgate-readiness

# Check only that the repo-tracked readiness manifest matches the suite.
check-floodgate-readiness-manifest:
    cd client && pnpm check:floodgate-readiness-manifest

# Run admin e2e tests (starts Docker server, runs Playwright, stops server)
test-e2e:
    cd client && pnpm test:integration:up
    cd client/packages/e2e && pnpm exec playwright test; result=$?; cd ../.. && pnpm test:integration:down; exit $result

# Run admin e2e tests (assumes server already running)
test-e2e-run:
    cd client/packages/e2e && pnpm exec playwright test

# === QUALITY ===

# Format all code (server + client)
format: format-server format-client

# Format server code
format-server: format-gleam format-elixir

# Format Gleam code
format-gleam:
    cd server/levee_auth && gleam format
    cd server/levee_storage && gleam format
    cd server/levee_oauth && gleam format
    cd server/levee_bridge && gleam format
    cd server/levee_admin && gleam format
    cd server/floodgate && gleam format

# Format Elixir code
format-elixir:
    cd server && mix format

# Format client code
format-client:
    cd client && pnpm format

# Lint all code (server + client)
lint: lint-server lint-client

# Lint server code
lint-server: lint-gleam lint-elixir

# Lint Gleam code (format check)
lint-gleam:
    cd server/levee_auth && gleam format --check
    cd server/levee_storage && gleam format --check
    cd server/levee_oauth && gleam format --check
    cd server/levee_bridge && gleam format --check
    cd server/levee_admin && gleam format --check
    cd server/floodgate && gleam format --check

# Lint Elixir code
lint-elixir:
    cd server && mix format --check-formatted
    cd server && mix compile --warnings-as-errors

# Lint client code
lint-client:
    cd client && pnpm lint

# Check formatting (alias for lint)
check-format: lint

# === CLEANUP ===

# Remove all build artifacts (server + client)
clean: clean-server clean-client

# Clean server build artifacts
clean-server: clean-gleam clean-elixir

clean-gleam:
    cd server/levee_auth && rm -rf build
    cd server/levee_storage && rm -rf build
    cd server/levee_oauth && rm -rf build
    cd server/levee_bridge && rm -rf build
    cd server/levee_admin && rm -rf build
    rm -rf server/priv/static/admin

clean-elixir:
    cd server && mix clean
    rm -rf server/_build server/deps

# Clean client build artifacts
clean-client:
    cd client && pnpm clean

# === DATABASE ===

# Default DATABASE_URL for local Docker PostgreSQL
export DATABASE_URL := env("DATABASE_URL", "postgres://levee:levee@localhost:5432/levee_test")

# Start PostgreSQL in Docker
db-start:
    docker compose up -d postgres
    @echo "Waiting for PostgreSQL..."
    @docker compose exec postgres sh -c 'until pg_isready -U levee -d levee_test; do sleep 0.5; done' 2>/dev/null
    @echo "PostgreSQL is ready at $DATABASE_URL"

# Stop PostgreSQL
db-stop:
    docker compose down

# Reset the test database (drop all tables, re-run migrations)
db-reset:
    docker compose exec postgres psql -U levee -d levee_test -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;"
    @echo "Database reset."

# Run Elixir tests including PostgreSQL backend tests
test-pg: db-start
    cd server && DATABASE_URL="$DATABASE_URL" mix test --include postgres

# === CI ===

# Full validation workflow (server + client)
ci: format lint test build

alias pr := ci

# === SETUP ===

# Install all dependencies (server + client)
setup: setup-server setup-client

# Install server dependencies
setup-server: setup-gleam setup-elixir

# Install Gleam dependencies
setup-gleam:
    cd server/levee_auth && gleam deps download
    cd server/levee_storage && gleam deps download
    cd server/levee_oauth && gleam deps download
    cd server/levee_bridge && gleam deps download
    cd server/levee_admin && gleam deps download

# Install Elixir dependencies
setup-elixir:
    cd server && mix deps.get

# Install client dependencies
setup-client:
    cd client && pnpm install

# === DEVELOPMENT ===

# Start dev server (alias for server)
start: server

# Start Phoenix server (builds Gleam + admin first)
server: build-gleam build-admin
    cd server && LEVEE_TENANT_ID=fluid LEVEE_TENANT_KEY=dev-tenant-secret-key mix phx.server

# Start Phoenix server with IEx
iex: build-gleam build-admin
    cd server && LEVEE_TENANT_ID=fluid LEVEE_TENANT_KEY=dev-tenant-secret-key iex -S mix phx.server

# Start Sandbag dev server (SvelteKit dev mode, proxies API to Phoenix)
dev-sandbag:
    cd client/packages/sandbag && pnpm dev

# === FLOODGATE STANDALONE ===

# Start standalone Floodgate server on :3000 with example credentials
floodgate-server:
    #!/usr/bin/env bash
    set -euo pipefail
    export FLOODGATE_JWT_SECRET=floodgate-example-jwt-secret
    export FLOODGATE_TOKEN_MINT_SECRET=floodgate-example-mint-secret
    export FLOODGATE_TOKEN_MINT_USER_ID=floodgate-example-user
    export FLOODGATE_TOKEN_MINT_USER_NAME="Floodgate Example User"
    export FLOODGATE_STORAGE_BACKEND=memory
    cd server/floodgate && gleam run

# Start Floodgate DiceRoller Vite dev server on :3001 (server must already be running).
# Env vars are pinned to match the standalone Floodgate server credentials.
dev-floodgate-example:
    #!/usr/bin/env bash
    set -euo pipefail
    export VITE_FLOODGATE_HTTP_URL=http://localhost:3000
    export VITE_FLOODGATE_SOCKET_URL=http://localhost:3000
    export VITE_FLOODGATE_TENANT_ID=fluid
    export VITE_FLOODGATE_TOKEN_MINT_SECRET=floodgate-example-mint-secret
    cd client/packages/floodgate-example && pnpm dev --port 3001 --strictPort

# Start Floodgate Todo List Vite dev server on :3002 (server must already be running).
# Env vars are pinned to match the standalone Floodgate server credentials.
dev-floodgate-todo-list:
    #!/usr/bin/env bash
    set -euo pipefail
    export VITE_FLOODGATE_HTTP_URL=http://localhost:3000
    export VITE_FLOODGATE_SOCKET_URL=http://localhost:3000
    export VITE_FLOODGATE_TENANT_ID=fluid
    export VITE_FLOODGATE_TOKEN_MINT_SECRET=floodgate-example-mint-secret
    cd client/packages/floodgate-todo-list && pnpm dev --port 3002 --strictPort

# Start Floodgate Presence Vite dev server on :3003 (server must already be running).
# Env vars are pinned to match the standalone Floodgate server credentials.
dev-floodgate-presence:
    #!/usr/bin/env bash
    set -euo pipefail
    export VITE_FLOODGATE_HTTP_URL=http://localhost:3000
    export VITE_FLOODGATE_SOCKET_URL=http://localhost:3000
    export VITE_FLOODGATE_TENANT_ID=fluid
    export VITE_FLOODGATE_TOKEN_MINT_SECRET=floodgate-example-mint-secret
    cd client/packages/floodgate-presence-tracker && pnpm dev --port 3003 --strictPort

# Start standalone Floodgate server (:3000) + DiceRoller example (:3001) together.
# Waits for the server to respond HTTP 200 before starting Vite. Terminates
# both children when either exits. Press Ctrl-C to stop.
# Uses example-only credentials — never use in production.
floodgate-example:
    #!/usr/bin/env bash
    set -euo pipefail

    # Server env vars
    export FLOODGATE_JWT_SECRET=floodgate-example-jwt-secret
    export FLOODGATE_TOKEN_MINT_SECRET=floodgate-example-mint-secret
    export FLOODGATE_TOKEN_MINT_USER_ID=floodgate-example-user
    export FLOODGATE_TOKEN_MINT_USER_NAME="Floodgate Example User"
    export FLOODGATE_STORAGE_BACKEND=memory

    # Vite env vars — pinned to match server credentials and port
    export VITE_FLOODGATE_HTTP_URL=http://localhost:3000
    export VITE_FLOODGATE_SOCKET_URL=http://localhost:3000
    export VITE_FLOODGATE_TENANT_ID=fluid
    export VITE_FLOODGATE_TOKEN_MINT_SECRET=floodgate-example-mint-secret

    floodgate_pid=""
    vite_pid=""

    cleanup() {
        # Kill the entire process group for each child (setsid gives each its own PGID).
        # This terminates BEAM/node descendants that outlive the group-leader bash.
        [ -n "$floodgate_pid" ] && kill -- "-$floodgate_pid" 2>/dev/null || true
        [ -n "$vite_pid" ] && kill -- "-$vite_pid" 2>/dev/null || true
    }
    trap cleanup EXIT INT TERM

    # setsid creates a new session/process group (PGID = $!) so cleanup can kill
    # the group leader and all descendants (gleam + BEAM, pnpm + node workers).
    scripts/setsid-portable bash -c 'cd server/floodgate && gleam run' &
    floodgate_pid=$!

    # Wait for authenticated token-mint to return HTTP 200 (proves server is fully up)
    echo "Waiting for Floodgate server to be ready..."
    ready=false
    for i in $(seq 1 30); do
        if ! kill -0 "$floodgate_pid" 2>/dev/null; then
            echo "ERROR: Floodgate server process exited unexpectedly." >&2
            exit 1
        fi
        code=$(curl --max-time 1 -s -o /dev/null -w "%{http_code}" \
            -X POST http://localhost:3000/api/tenants/fluid/token-mint \
            -H "Authorization: Bearer $FLOODGATE_TOKEN_MINT_SECRET" \
            -H "Content-Type: application/json" \
            -d '{"documentId":""}' \
            2>/dev/null) || code="000"
        if [ "$code" = "200" ]; then
            echo "  Floodgate server ready (HTTP 200)."
            ready=true
            break
        fi
        echo "  waiting... ($i/30)"
        sleep 1
    done
    if [ "$ready" = "false" ]; then
        echo "ERROR: Floodgate server not ready after 30s." >&2
        exit 1
    fi

    # Start Vite on fixed port 3001 (--strictPort fails immediately if port is taken)
    scripts/setsid-portable bash -c 'cd client/packages/floodgate-example && pnpm dev --port 3001 --strictPort' &
    vite_pid=$!

    # Detect immediate Vite startup failure (e.g., port 3001 in use)
    sleep 2
    if ! kill -0 "$vite_pid" 2>/dev/null; then
        echo "ERROR: Vite dev server failed to start (port 3001 may be in use)." >&2
        exit 1
    fi

    echo ""
    echo "  Floodgate server:   http://localhost:3000"
    echo "  DiceRoller example: http://localhost:3001"
    echo ""
    echo "  Press Ctrl-C to stop both processes."
    echo ""

    # Terminate the surviving child when either process exits
    while kill -0 "$floodgate_pid" 2>/dev/null && kill -0 "$vite_pid" 2>/dev/null; do
        sleep 1
    done

# Start standalone Floodgate server (:3000) + Presence demo (:3003) together.
# Uses example-only credentials — never use in production.
floodgate-presence:
    #!/usr/bin/env bash
    set -euo pipefail

    export FLOODGATE_JWT_SECRET=floodgate-example-jwt-secret
    export FLOODGATE_TOKEN_MINT_SECRET=floodgate-example-mint-secret
    export FLOODGATE_TOKEN_MINT_USER_ID=floodgate-example-user
    export FLOODGATE_TOKEN_MINT_USER_NAME="Floodgate Example User"
    export FLOODGATE_STORAGE_BACKEND=memory
    export VITE_FLOODGATE_HTTP_URL=http://localhost:3000
    export VITE_FLOODGATE_SOCKET_URL=http://localhost:3000
    export VITE_FLOODGATE_TENANT_ID=fluid
    export VITE_FLOODGATE_TOKEN_MINT_SECRET=floodgate-example-mint-secret

    floodgate_pid=""
    vite_pid=""
    cleanup() {
        [ -n "$floodgate_pid" ] && kill -- "-$floodgate_pid" 2>/dev/null || true
        [ -n "$vite_pid" ] && kill -- "-$vite_pid" 2>/dev/null || true
    }
    trap cleanup EXIT INT TERM

    scripts/setsid-portable bash -c 'cd server/floodgate && gleam run' &
    floodgate_pid=$!

    echo "Waiting for Floodgate server to be ready..."
    ready=false
    for i in $(seq 1 30); do
        if ! kill -0 "$floodgate_pid" 2>/dev/null; then
            echo "ERROR: Floodgate server process exited unexpectedly." >&2
            exit 1
        fi
        code=$(curl --max-time 1 -s -o /dev/null -w "%{http_code}" \
            -X POST http://localhost:3000/api/tenants/fluid/token-mint \
            -H "Authorization: Bearer floodgate-example-mint-secret" \
            -H "Content-Type: application/json" \
            -d '{"documentId":""}' \
            2>/dev/null) || code="000"
        if [ "$code" = "200" ]; then
            echo "  Floodgate server ready (HTTP 200)."
            ready=true
            break
        fi
        echo "  waiting... ($i/30)"
        sleep 1
    done
    if [ "$ready" = "false" ]; then
        echo "ERROR: Floodgate server not ready after 30s." >&2
        exit 1
    fi

    scripts/setsid-portable bash -c 'cd client/packages/floodgate-presence-tracker && pnpm dev --port 3003 --strictPort' &
    vite_pid=$!
    sleep 2
    if ! kill -0 "$vite_pid" 2>/dev/null; then
        echo "ERROR: Vite dev server failed to start (port 3003 may be in use)." >&2
        exit 1
    fi

    echo ""
    echo "  Floodgate server: http://localhost:3000"
    echo "  Presence demo:    http://localhost:3003"
    echo ""
    echo "  Press Ctrl-C to stop both processes."
    echo ""

    while kill -0 "$floodgate_pid" 2>/dev/null && kill -0 "$vite_pid" 2>/dev/null; do
        sleep 1
    done

# Start standalone Floodgate server (:3000) + Todo List example (:3002) together.
# Waits for the server to respond HTTP 200 before starting Vite. Terminates
# both children when either exits. Press Ctrl-C to stop.
# Uses example-only credentials — never use in production.
floodgate-todo-list:
    #!/usr/bin/env bash
    set -euo pipefail

    # Server env vars
    export FLOODGATE_JWT_SECRET=floodgate-example-jwt-secret
    export FLOODGATE_TOKEN_MINT_SECRET=floodgate-example-mint-secret
    export FLOODGATE_TOKEN_MINT_USER_ID=floodgate-example-user
    export FLOODGATE_TOKEN_MINT_USER_NAME="Floodgate Example User"
    export FLOODGATE_STORAGE_BACKEND=memory

    # Vite env vars — pinned to match server credentials and port
    export VITE_FLOODGATE_HTTP_URL=http://localhost:3000
    export VITE_FLOODGATE_SOCKET_URL=http://localhost:3000
    export VITE_FLOODGATE_TENANT_ID=fluid
    export VITE_FLOODGATE_TOKEN_MINT_SECRET=floodgate-example-mint-secret

    floodgate_pid=""
    vite_pid=""

    cleanup() {
        # Kill the entire process group for each child (setsid gives each its own PGID).
        # This terminates BEAM/node descendants that outlive the group-leader bash.
        [ -n "$floodgate_pid" ] && kill -- "-$floodgate_pid" 2>/dev/null || true
        [ -n "$vite_pid" ] && kill -- "-$vite_pid" 2>/dev/null || true
    }
    trap cleanup EXIT INT TERM

    # setsid creates a new session/process group (PGID = $!) so cleanup can kill
    # the group leader and all descendants (gleam + BEAM, pnpm + node workers).
    scripts/setsid-portable bash -c 'cd server/floodgate && gleam run' &
    floodgate_pid=$!

    # Wait for authenticated token-mint to return HTTP 200 (proves server is fully up)
    echo "Waiting for Floodgate server to be ready..."
    ready=false
    for i in $(seq 1 30); do
        if ! kill -0 "$floodgate_pid" 2>/dev/null; then
            echo "ERROR: Floodgate server process exited unexpectedly." >&2
            exit 1
        fi
        code=$(curl --max-time 1 -s -o /dev/null -w "%{http_code}" \
            -X POST http://localhost:3000/api/tenants/fluid/token-mint \
            -H "Authorization: ******" \
            -H "Content-Type: application/json" \
            -d '{"documentId":""}' \
            2>/dev/null) || code="000"
        if [ "$code" = "200" ]; then
            echo "  Floodgate server ready (HTTP 200)."
            ready=true
            break
        fi
        echo "  waiting... ($i/30)"
        sleep 1
    done
    if [ "$ready" = "false" ]; then
        echo "ERROR: Floodgate server not ready after 30s." >&2
        exit 1
    fi

    # Start Vite on fixed port 3002 (--strictPort fails immediately if port is taken)
    scripts/setsid-portable bash -c 'cd client/packages/floodgate-todo-list && pnpm dev --port 3002 --strictPort' &
    vite_pid=$!

    # Detect immediate Vite startup failure (e.g., port 3002 in use)
    sleep 2
    if ! kill -0 "$vite_pid" 2>/dev/null; then
        echo "ERROR: Vite dev server failed to start (port 3002 may be in use)." >&2
        exit 1
    fi

    echo ""
    echo "  Floodgate server:  http://localhost:3000"
    echo "  Todo List example: http://localhost:3002"
    echo ""
    echo "  Press Ctrl-C to stop both processes."
    echo ""

    # Terminate the surviving child when either process exits
    while kill -0 "$floodgate_pid" 2>/dev/null && kill -0 "$vite_pid" 2>/dev/null; do
        sleep 1
    done

# Run the two-client SharedMap sync integration test against standalone Floodgate.
# Starts the server, polls the authenticated token-mint for HTTP 200, runs the
# test, then stops the server. Fails explicitly if the server does not start.
test-floodgate-sync:
    #!/usr/bin/env bash
    set -euo pipefail

    export FLOODGATE_JWT_SECRET=floodgate-example-jwt-secret
    export FLOODGATE_TOKEN_MINT_SECRET=floodgate-example-mint-secret
    export FLOODGATE_TOKEN_MINT_USER_ID=floodgate-example-user
    export FLOODGATE_TOKEN_MINT_USER_NAME="Floodgate Example User"
    export FLOODGATE_STORAGE_BACKEND=memory

    server_pid=""
    cleanup() {
        # Kill the entire process group to terminate BEAM descendants.
        [ -n "$server_pid" ] && kill -- "-$server_pid" 2>/dev/null || true
    }
    trap cleanup EXIT INT TERM

    # setsid: new session/PGID = $server_pid so kill -- -$server_pid reaches BEAM.
    scripts/setsid-portable bash -c 'cd server/floodgate && gleam run' &
    server_pid=$!

    # Detect immediate server startup failure
    sleep 0.5
    if ! kill -0 "$server_pid" 2>/dev/null; then
        echo "ERROR: Floodgate server process exited immediately." >&2
        exit 1
    fi

    # Poll authenticated token-mint; require HTTP 200 to confirm server is fully up
    echo "Waiting for Floodgate server to be ready..."
    ready=false
    for i in $(seq 1 30); do
        code=$(curl --max-time 1 -s -o /dev/null -w "%{http_code}" \
            -X POST http://localhost:3000/api/tenants/fluid/token-mint \
            -H "Authorization: Bearer $FLOODGATE_TOKEN_MINT_SECRET" \
            -H "Content-Type: application/json" \
            -d '{"documentId":""}' \
            2>/dev/null) || code="000"
        if [ "$code" = "200" ]; then
            echo "Floodgate server ready (HTTP 200)."
            ready=true
            break
        fi
        echo "  waiting... ($i/30)"
        sleep 1
    done
    if [ "$ready" = "false" ]; then
        echo "ERROR: Floodgate server not ready after 30s." >&2
        exit 1
    fi

    cd client/packages/floodgate-example
    FLOODGATE_INTEGRATION=1 \
    FLOODGATE_HTTP_URL=http://localhost:3000 \
    FLOODGATE_MINT_CREDENTIAL=floodgate-example-mint-secret \
    pnpm test:vitest:integration

# Run the two-client SharedTree + SharedString sync integration test against standalone Floodgate.
# Starts the server, polls the authenticated token-mint for HTTP 200, runs the
# test, then stops the server. Fails explicitly if the server does not start.
test-floodgate-todo-sync:
    #!/usr/bin/env bash
    set -euo pipefail

    export FLOODGATE_JWT_SECRET=floodgate-example-jwt-secret
    export FLOODGATE_TOKEN_MINT_SECRET=floodgate-example-mint-secret
    export FLOODGATE_TOKEN_MINT_USER_ID=floodgate-example-user
    export FLOODGATE_TOKEN_MINT_USER_NAME="Floodgate Example User"
    export FLOODGATE_STORAGE_BACKEND=memory

    server_pid=""
    cleanup() {
        # Kill the entire process group to terminate BEAM descendants.
        [ -n "$server_pid" ] && kill -- "-$server_pid" 2>/dev/null || true
    }
    trap cleanup EXIT INT TERM

    # setsid: new session/PGID = $server_pid so kill -- -$server_pid reaches BEAM.
    scripts/setsid-portable bash -c 'cd server/floodgate && gleam run' &
    server_pid=$!

    # Detect immediate server startup failure
    sleep 0.5
    if ! kill -0 "$server_pid" 2>/dev/null; then
        echo "ERROR: Floodgate server process exited immediately." >&2
        exit 1
    fi

    # Poll authenticated token-mint; require HTTP 200 to confirm server is fully up
    echo "Waiting for Floodgate server to be ready..."
    ready=false
    for i in $(seq 1 30); do
        code=$(curl --max-time 1 -s -o /dev/null -w "%{http_code}" \
            -X POST http://localhost:3000/api/tenants/fluid/token-mint \
            -H "Authorization: Bearer $FLOODGATE_TOKEN_MINT_SECRET" \
            -H "Content-Type: application/json" \
            -d '{"documentId":""}' \
            2>/dev/null) || code="000"
        if [ "$code" = "200" ]; then
            echo "Floodgate server ready (HTTP 200)."
            ready=true
            break
        fi
        echo "  waiting... ($i/30)"
        sleep 1
    done
    if [ "$ready" = "false" ]; then
        echo "ERROR: Floodgate server not ready after 30s." >&2
        exit 1
    fi

    cd client/packages/floodgate-todo-list
    FLOODGATE_INTEGRATION=1 \
    FLOODGATE_HTTP_URL=http://localhost:3000 \
    FLOODGATE_MINT_CREDENTIAL=floodgate-example-mint-secret \
    pnpm test:vitest:integration

# Run two-client Fluid Presence state and notification synchronization.
test-floodgate-presence-sync:
    #!/usr/bin/env bash
    set -euo pipefail

    export FLOODGATE_JWT_SECRET=floodgate-example-jwt-secret
    export FLOODGATE_TOKEN_MINT_SECRET=floodgate-example-mint-secret
    export FLOODGATE_TOKEN_MINT_USER_ID=floodgate-example-user
    export FLOODGATE_TOKEN_MINT_USER_NAME="Floodgate Example User"
    export FLOODGATE_STORAGE_BACKEND=memory

    server_pid=""
    cleanup() {
        [ -n "$server_pid" ] && kill -- "-$server_pid" 2>/dev/null || true
    }
    trap cleanup EXIT INT TERM

    scripts/setsid-portable bash -c 'cd server/floodgate && gleam run' &
    server_pid=$!

    sleep 0.5
    if ! kill -0 "$server_pid" 2>/dev/null; then
        echo "ERROR: Floodgate server process exited immediately." >&2
        exit 1
    fi

    echo "Waiting for Floodgate server to be ready..."
    ready=false
    for i in $(seq 1 30); do
        if ! kill -0 "$server_pid" 2>/dev/null; then
            echo "ERROR: Floodgate server process exited unexpectedly." >&2
            exit 1
        fi
        code=$(curl --max-time 1 -s -o /dev/null -w "%{http_code}" \
            -X POST http://localhost:3000/api/tenants/fluid/token-mint \
            -H "Authorization: Bearer floodgate-example-mint-secret" \
            -H "Content-Type: application/json" \
            -d '{"documentId":""}' \
            2>/dev/null) || code="000"
        if [ "$code" = "200" ]; then
            echo "Floodgate server ready (HTTP 200)."
            ready=true
            break
        fi
        echo "  waiting... ($i/30)"
        sleep 1
    done
    if [ "$ready" = "false" ]; then
        echo "ERROR: Floodgate server not ready after 30s." >&2
        exit 1
    fi

    cd client/packages/floodgate-presence-tracker
    FLOODGATE_INTEGRATION=1 \
    FLOODGATE_HTTP_URL=http://localhost:3000 \
    FLOODGATE_MINT_CREDENTIAL=floodgate-example-mint-secret \
    pnpm test:vitest:integration

# === DOCKER ===

# Docker image name
docker_image := "levee-server"

# Build Docker image locally (uses root Dockerfile with client + server)
docker-build tag=docker_image:
    docker build -t {{tag}} .

# Verify Docker image starts and passes health check
docker-verify tag=docker_image:
    #!/usr/bin/env bash
    set -euo pipefail
    container_name="levee-verify-$$"
    cleanup() { docker rm -f "$container_name" >/dev/null 2>&1 || true; }
    trap cleanup EXIT

    echo "Starting container from {{tag}}..."
    docker run -d --name "$container_name" \
        -p 0:4000 \
        "{{tag}}"

    # Get the randomly assigned host port
    host_port=$(docker port "$container_name" 4000/tcp | head -1 | cut -d: -f2)
    echo "Container running on port $host_port"

    echo "Waiting for health check..."
    for i in $(seq 1 30); do
        if curl -sf "http://localhost:$host_port/health" >/dev/null 2>&1; then
            echo "Health check passed!"
            docker logs "$container_name" 2>&1 | tail -5
            exit 0
        fi
        echo "  attempt $i/30..."
        sleep 2
    done

    echo "Health check failed after 60s. Container logs:"
    docker logs "$container_name" 2>&1
    exit 1

# Build and verify Docker image
docker-test tag=docker_image: (docker-build tag) (docker-verify tag)

# === CODE GENERATION ===

# Generate JSON schema from Gleam protocol types
generate-schema:
    cd server && mix generate_schema

# Generate schema and copy to client driver package
generate-schema-ts: generate-schema
    mkdir -p client/packages/levee-driver/schemas
    cp server/priv/protocol-schema.json client/packages/levee-driver/schemas/
