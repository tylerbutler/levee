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

# Run E2E tests (requires server running: just server)
test-e2e:
    cd e2e && pnpm exec playwright test

# Run E2E tests with visible browser
test-e2e-headed:
    cd e2e && pnpm exec playwright test --headed

# Run E2E tests with Playwright UI
test-e2e-ui:
    cd e2e && pnpm exec playwright test --ui

# === QUALITY ===

# Format all code (server + client)
format: format-server format-client

# Format server code
format-server: format-gleam format-elixir

# Format Gleam code
format-gleam:
    cd server/levee_protocol && gleam format
    cd server/levee_auth && gleam format
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
    cd server/levee_oauth && rm -rf build
    cd server/levee_admin && rm -rf build
    rm -rf server/priv/static/admin

clean-elixir:
    cd server && mix clean
    rm -rf server/_build server/deps

# Clean client build artifacts
clean-client:
    cd client && pnpm clean

# === CI ===

# Full validation workflow (server + client)
ci: format lint test build

alias pr := ci

# === SETUP ===

# Install all dependencies (server + client + e2e)
setup: setup-server setup-client setup-e2e

# Install server dependencies
setup-server: setup-gleam setup-elixir

# Install Gleam dependencies
setup-gleam:
    cd server/levee_protocol && gleam deps download
    cd server/levee_auth && gleam deps download
    cd server/levee_oauth && gleam deps download
    cd server/levee_admin && gleam deps download

# Install Elixir dependencies
setup-elixir:
    cd server && mix deps.get

# Install client dependencies
setup-client:
    cd client && pnpm install

# Install E2E test dependencies
setup-e2e:
    cd e2e && pnpm install

# === DEVELOPMENT ===

# Start dev server (alias for server)
start: server

# Start Phoenix server (builds Gleam + admin first)
server: build-gleam build-admin
    cd server && mix phx.server

# Start Phoenix server with IEx
iex: build-gleam build-admin
    cd server && iex -S mix phx.server

# === CODE GENERATION ===

# Generate JSON schema from Gleam protocol types
generate-schema:
    cd server && mix generate_schema

# Generate schema and copy to client driver package
generate-schema-ts: generate-schema
    mkdir -p client/packages/levee-driver/schemas
    cp server/priv/protocol-schema.json client/packages/levee-driver/schemas/
