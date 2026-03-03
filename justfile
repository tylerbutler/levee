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
build: build-server build-client

# Build server (Gleam + admin + Elixir)
build-server: build-gleam build-admin build-elixir

# Build Gleam packages
build-gleam:
    cd server/levee_protocol && gleam build --target erlang
    cd server/levee_auth && gleam build --target erlang
    cd server/levee_storage && gleam build --target erlang
    cd server/levee_oauth && gleam build --target erlang
    cd server/levee_admin && gleam build --target javascript

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

# === TESTING ===

# Run all tests (server + client)
test: test-server test-client

# Run all tests including PostgreSQL backend
test-all: test-server test-client test-pg

# Run all server tests
test-server: test-gleam test-elixir

# Run Gleam tests
test-gleam:
    cd server/levee_protocol && gleam test
    cd server/levee_auth && gleam test
    cd server/levee_oauth && gleam test
    cd server/levee_admin && gleam test

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

# === QUALITY ===

# Format all code (server + client)
format: format-server format-client

# Format server code
format-server: format-gleam format-elixir

# Format Gleam code
format-gleam:
    cd server/levee_protocol && gleam format
    cd server/levee_auth && gleam format
    cd server/levee_storage && gleam format
    cd server/levee_oauth && gleam format
    cd server/levee_admin && gleam format

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
    cd server/levee_protocol && gleam format --check
    cd server/levee_auth && gleam format --check
    cd server/levee_storage && gleam format --check
    cd server/levee_oauth && gleam format --check
    cd server/levee_admin && gleam format --check

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
    cd server/levee_protocol && rm -rf build
    cd server/levee_auth && rm -rf build
    cd server/levee_storage && rm -rf build
    cd server/levee_oauth && rm -rf build
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
    cd server/levee_protocol && gleam deps download
    cd server/levee_auth && gleam deps download
    cd server/levee_storage && gleam deps download
    cd server/levee_oauth && gleam deps download
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
    cd server && mix phx.server

# Start Phoenix server with IEx
iex: build-gleam build-admin
    cd server && iex -S mix phx.server

# === DOCKER ===

# Docker image name
docker_image := "levee-server"

# Build Docker image locally
docker-build tag=docker_image:
    docker build -t {{tag}} ./server

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
        -e PHX_SERVER=true \
        -e PHX_HOST=localhost \
        -e PORT=4000 \
        -e SECRET_KEY_BASE=dev-only-secret-key-base-at-least-64-characters-long-for-phoenix-framework \
        -e LEVEE_TENANT_ID=fluid \
        -e LEVEE_TENANT_KEY=dev-tenant-secret-key \
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
