# Levee - Elixir + Gleam collaborative document service

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

# Build everything
build: build-gleam build-admin build-elixir

# Build Gleam packages
build-gleam:
    cd levee_protocol && gleam build --target erlang
    cd levee_auth && gleam build --target erlang
    cd beryl && gleam build --target erlang
    cd levee_channels && gleam build --target erlang
    cd levee_admin && gleam build --target javascript

# Build admin UI and copy to priv/static/admin
build-admin: build-gleam
    mkdir -p priv/static/admin
    cp -r levee_admin/build/dev/javascript/* priv/static/admin/
    cp levee_admin/index.html priv/static/admin/

# Build Elixir application
build-elixir: build-gleam
    mix compile

# === TESTING ===

# Run all tests
test: test-gleam test-elixir

# Run Gleam tests
test-gleam:
    cd levee_protocol && gleam test
    cd levee_auth && gleam test
    cd beryl && gleam test
    cd levee_admin && gleam test

# Run Elixir tests
test-elixir:
    mix test

# === QUALITY ===

# Format all code
format: format-gleam format-elixir

# Format Gleam code
format-gleam:
    cd levee_protocol && gleam format
    cd levee_auth && gleam format
    cd levee_admin && gleam format

# Format Elixir code
format-elixir:
    mix format

# Lint all code
lint: lint-gleam lint-elixir

# Lint Gleam code (format check)
lint-gleam:
    cd levee_protocol && gleam format --check
    cd levee_auth && gleam format --check
    cd levee_admin && gleam format --check

# Lint Elixir code
lint-elixir:
    mix format --check-formatted
    mix compile --warnings-as-errors

# Check formatting (alias for lint)
check-format: lint

# Remove all build artifacts
clean: clean-gleam clean-elixir

clean-gleam:
    cd levee_protocol && rm -rf build
    cd levee_auth && rm -rf build
    cd levee_admin && rm -rf build
    rm -rf priv/static/admin

clean-elixir:
    mix clean
    rm -rf _build deps

# Full validation workflow
ci: format lint test build

alias pr := ci

# === SETUP ===

# Install all dependencies
setup: setup-gleam setup-elixir

# Install Gleam dependencies
setup-gleam:
    cd levee_protocol && gleam deps download
    cd levee_auth && gleam deps download
    cd levee_admin && gleam deps download

# Install Elixir dependencies
setup-elixir:
    mix deps.get

# === DEVELOPMENT ===

# Start dev server (alias for server)
start: server

# Start Phoenix server (builds Gleam + admin first)
server: build-gleam build-admin
    mix phx.server

# Start Phoenix server with IEx
iex: build-gleam build-admin
    iex -S mix phx.server

# === CODE GENERATION ===

# Generate JSON schema from Gleam protocol types
generate-schema:
    mix generate_schema

# Generate schema and copy to TypeScript project
generate-schema-ts: generate-schema
    mkdir -p ../tools-monorepo/packages/levee-driver/schemas
    cp priv/protocol-schema.json ../tools-monorepo/packages/levee-driver/schemas/
