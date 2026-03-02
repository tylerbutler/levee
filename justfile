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

# Build server (Gleam + admin)
build-server: build-gleam build-admin

# Build Gleam packages
build-gleam:
    cd server/levee_protocol && gleam build --target erlang
    cd server/levee_auth && gleam build --target erlang
    cd server/levee_storage && gleam build --target erlang
    cd server/levee_session && gleam build --target erlang
    cd server/levee_oauth && gleam build --target erlang
    cd server/levee_web && gleam build --target erlang
    cd levee_channels && gleam build --target erlang
    cd server/levee_admin && gleam build --target javascript

# Build admin UI and copy to priv/static/admin
build-admin: build-gleam
    mkdir -p server/priv/static/admin
    cp -r server/levee_admin/build/dev/javascript/* server/priv/static/admin/
    cp server/levee_admin/index.html server/priv/static/admin/

# Build client (TypeScript)
build-client:
    cd client && pnpm install && pnpm build

# === TESTING ===

# Run all tests (server + client)
test: test-server test-client

# Run all server tests
test-server: test-gleam

# Run Gleam tests
test-gleam:
    cd server/levee_protocol && gleam test
    cd server/levee_auth && gleam test
    cd server/levee_session && gleam test
    cd server/levee_oauth && gleam test
    cd server/levee_web && gleam test
    cd levee_channels && gleam test
    cd server/levee_admin && gleam test

# Run client tests
test-client:
    cd client && pnpm install && pnpm test

# === QUALITY ===

# Format all code (server + client)
format: format-server format-client

# Format server code
format-server: format-gleam

# Format Gleam code
format-gleam:
    cd server/levee_protocol && gleam format
    cd server/levee_auth && gleam format
    cd server/levee_storage && gleam format
    cd server/levee_session && gleam format
    cd server/levee_oauth && gleam format
    cd server/levee_web && gleam format
    cd levee_channels && gleam format
    cd server/levee_admin && gleam format

# Format client code
format-client:
    cd client && pnpm format

# Lint all code (server + client)
lint: lint-server lint-client

# Lint server code
lint-server: lint-gleam

# Lint Gleam code (format check)
lint-gleam:
    cd server/levee_protocol && gleam format --check
    cd server/levee_auth && gleam format --check
    cd server/levee_storage && gleam format --check
    cd server/levee_session && gleam format --check
    cd server/levee_oauth && gleam format --check
    cd server/levee_web && gleam format --check
    cd levee_channels && gleam format --check
    cd server/levee_admin && gleam format --check

# Lint client code
lint-client:
    cd client && pnpm lint

# Check formatting (alias for lint)
check-format: lint

# === CLEANUP ===

# Remove all build artifacts (server + client)
clean: clean-server clean-client

# Clean server build artifacts
clean-server: clean-gleam

clean-gleam:
    cd server/levee_protocol && rm -rf build
    cd server/levee_auth && rm -rf build
    cd server/levee_storage && rm -rf build
    cd server/levee_session && rm -rf build
    cd server/levee_oauth && rm -rf build
    cd server/levee_web && rm -rf build
    cd levee_channels && rm -rf build
    cd server/levee_admin && rm -rf build
    rm -rf server/priv/static/admin

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

# === CI ===

# Full validation workflow (server + client)
ci: format lint test build

alias pr := ci

# === SETUP ===

# Install all dependencies (server + client)
setup: setup-server setup-client

# Install server dependencies
setup-server: setup-gleam

# Install Gleam dependencies
setup-gleam:
    cd server/levee_protocol && gleam deps download
    cd server/levee_auth && gleam deps download
    cd server/levee_storage && gleam deps download
    cd server/levee_session && gleam deps download
    cd server/levee_oauth && gleam deps download
    cd server/levee_web && gleam deps download
    cd levee_channels && gleam deps download
    cd server/levee_admin && gleam deps download

# Install client dependencies
setup-client:
    cd client && pnpm install

# === DEVELOPMENT ===

# Start dev server (alias for server)
start: server

# Start server (builds Gleam + admin first)
server: build-gleam build-admin
    cd server/levee_web && gleam run

# === CODE GENERATION ===

# Generate JSON schema from Gleam protocol types
generate-schema:
    cd server/levee_protocol && gleam run -m generate_schema

# Generate schema and copy to client driver package
generate-schema-ts: generate-schema
    mkdir -p client/packages/levee-driver/schemas
    cp server/priv/protocol-schema.json client/packages/levee-driver/schemas/
