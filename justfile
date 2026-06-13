# Levee - Collaborative document service (Gleam server + TypeScript client)

alias b := build
alias t := test
alias f := format
alias l := lint
alias c := clean

server_packages := "levee_protocol levee_auth levee_storage levee_oauth levee_documents levee_server"

default:
    @just --list

# === BUILD ===

build: build-server build-client build-sandbag

# Build the Gleam server packages and the JavaScript admin UI.
build-server: build-gleam build-admin

build-gleam:
    cd server/levee_protocol && gleam build
    cd server/levee_auth && gleam build
    cd server/levee_storage && gleam build
    cd server/levee_oauth && gleam build
    cd server/levee_documents && gleam build
    cd server/levee_server && gleam build

build-admin:
    cd server/levee_admin && gleam build --target javascript
    mkdir -p server/priv/static/admin
    cp -r server/levee_admin/build/dev/javascript/* server/priv/static/admin/
    cp server/levee_admin/index.html server/priv/static/admin/

# Backward-compatible aliases; Elixir has been removed.
build-elixir: build-gleam
compile: build-server

build-client:
    cd client && pnpm install && pnpm build

build-sandbag:
    cd client/packages/sandbag && pnpm build
    mkdir -p server/priv/static/sandbag
    cp -r client/packages/sandbag/build/* server/priv/static/sandbag/

# === TESTING ===

test: test-server test-client

test-all: test-server test-client test-pg

test-server: test-gleam

test-gleam:
    cd server/levee_protocol && gleam test
    cd server/levee_auth && gleam test
    cd server/levee_storage && gleam test
    cd server/levee_oauth && gleam test
    cd server/levee_documents && gleam test
    cd server/levee_server && gleam test

test-elixir: test-gleam

test-client:
    cd client && pnpm install && pnpm test

test-integration:
    cd client && pnpm test:integration

test-integration-up:
    cd client && pnpm test:integration:up

test-integration-down:
    cd client && pnpm test:integration:down

test-integration-run:
    cd client && pnpm test:integration:run

test-e2e:
    cd client && pnpm test:integration:up
    cd client/packages/e2e && pnpm exec playwright test; result=$?; cd ../.. && pnpm test:integration:down; exit $result

test-e2e-run:
    cd client/packages/e2e && pnpm exec playwright test

# PostgreSQL backend coverage now lives in Gleam storage tests.
test-pg: db-start
    cd server/levee_storage && DATABASE_URL="$DATABASE_URL" gleam test

# === QUALITY ===

format: format-server format-client

format-server: format-gleam

format-gleam:
    cd server/levee_protocol && gleam format
    cd server/levee_auth && gleam format
    cd server/levee_storage && gleam format
    cd server/levee_oauth && gleam format
    cd server/levee_documents && gleam format
    cd server/levee_server && gleam format
    cd server/levee_admin && gleam format

format-elixir: format-gleam

format-client:
    cd client && pnpm format

lint: lint-server lint-client

lint-server: lint-gleam

lint-gleam:
    cd server/levee_protocol && gleam format --check
    cd server/levee_auth && gleam format --check
    cd server/levee_storage && gleam format --check
    cd server/levee_oauth && gleam format --check
    cd server/levee_documents && gleam format --check
    cd server/levee_server && gleam format --check
    cd server/levee_admin && gleam format --check

lint-elixir: lint-gleam

lint-client:
    cd client && pnpm lint

check-format: lint

# === CLEANUP ===

clean: clean-server clean-client

clean-server: clean-gleam

clean-gleam:
    cd server/levee_protocol && rm -rf build
    cd server/levee_auth && rm -rf build
    cd server/levee_storage && rm -rf build
    cd server/levee_oauth && rm -rf build
    cd server/levee_documents && rm -rf build
    cd server/levee_server && rm -rf build
    cd server/levee_admin && rm -rf build
    rm -rf server/priv/static/admin server/priv/static/sandbag

clean-elixir: clean-gleam

clean-client:
    cd client && pnpm clean

# === DATABASE ===

export DATABASE_URL := env("DATABASE_URL", "postgres://levee:levee@localhost:5432/levee_test")

db-start:
    docker compose up -d postgres
    @echo "Waiting for PostgreSQL..."
    @docker compose exec postgres sh -c 'until pg_isready -U levee -d levee_test; do sleep 0.5; done' 2>/dev/null
    @echo "PostgreSQL is ready at $DATABASE_URL"

db-stop:
    docker compose down

db-reset:
    docker compose exec postgres psql -U levee -d levee_test -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;"
    @echo "Database reset."

# === CI ===

ci: format lint test build

alias pr := ci

# === SETUP ===

setup: setup-server setup-client

setup-server: setup-gleam

setup-gleam:
    cd server/levee_protocol && gleam deps download
    cd server/levee_auth && gleam deps download
    cd server/levee_storage && gleam deps download
    cd server/levee_oauth && gleam deps download
    cd server/levee_documents && gleam deps download
    cd server/levee_server && gleam deps download
    cd server/levee_admin && gleam deps download

setup-elixir: setup-gleam

setup-client:
    cd client && pnpm install

# === DEVELOPMENT ===

start: server

server: build-server
    cd server/levee_server && PORT=${PORT:-4000} LEVEE_TENANT_ID=${LEVEE_TENANT_ID:-fluid} LEVEE_TENANT_KEY=${LEVEE_TENANT_KEY:-dev-tenant-secret-key} gleam run

# Elixir shell is gone; keep this alias as a useful BEAM shell for the Gleam server.
iex: server

dev-sandbag:
    cd client/packages/sandbag && pnpm dev

# === DOCKER ===

docker_image := "levee-server"

docker-build tag=docker_image:
    docker build -t {{tag}} .

docker-verify tag=docker_image:
    #!/usr/bin/env bash
    set -euo pipefail
    container_name="levee-verify-$$"
    cleanup() { docker rm -f "$container_name" >/dev/null 2>&1 || true; }
    trap cleanup EXIT
    docker run -d --name "$container_name" -p 0:4000 "{{tag}}"
    host_port=$(docker port "$container_name" 4000/tcp | head -1 | cut -d: -f2)
    for i in $(seq 1 30); do
        if curl -sf "http://localhost:$host_port/health" >/dev/null 2>&1; then
            echo "Health check passed"
            exit 0
        fi
        sleep 2
    done
    docker logs "$container_name" 2>&1
    exit 1

docker-test tag=docker_image: (docker-build tag) (docker-verify tag)

# === CODE GENERATION ===

# Generate JSON schema from Gleam protocol types.
generate-schema:
    mkdir -p server/priv
    cd server/levee_protocol && gleam run -m schema_cli | python3 -m json.tool > ../priv/protocol-schema.json

generate-schema-ts: generate-schema
    mkdir -p client/packages/levee-driver/schemas
    cp server/priv/protocol-schema.json client/packages/levee-driver/schemas/
