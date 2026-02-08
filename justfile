# Levee - Elixir + Gleam
# Task runner for polyglot project

set dotenv-load

# Default recipe
default:
    @just --list

# ─────────────────────────────────────────────────────────────────────────────
# Setup
# ─────────────────────────────────────────────────────────────────────────────

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

# ─────────────────────────────────────────────────────────────────────────────
# Build
# ─────────────────────────────────────────────────────────────────────────────

# Build everything
build: build-gleam build-elixir

# Build Gleam packages
build-gleam:
    cd levee_protocol && gleam build --target erlang
    cd levee_auth && gleam build --target erlang
    cd levee_admin && gleam build --target javascript

# Build Elixir application
build-elixir: build-gleam
    mix compile

# ─────────────────────────────────────────────────────────────────────────────
# Test
# ─────────────────────────────────────────────────────────────────────────────

# Run all tests
test: test-gleam test-elixir

# Run Gleam tests
test-gleam:
    cd levee_protocol && gleam test
    cd levee_auth && gleam test
    cd levee_admin && gleam test

# Run Elixir tests
test-elixir:
    mix test

# ─────────────────────────────────────────────────────────────────────────────
# Development
# ─────────────────────────────────────────────────────────────────────────────

# Start Phoenix server (builds Gleam first)
server: build-gleam
    mix phx.server

# Start Phoenix server with IEx
iex: build-gleam
    iex -S mix phx.server

# Development mode with auto-rebuild
dev: build
    mix phx.server

# ─────────────────────────────────────────────────────────────────────────────
# Quality
# ─────────────────────────────────────────────────────────────────────────────

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

# Check formatting
check-format: check-format-gleam check-format-elixir

check-format-gleam:
    cd levee_protocol && gleam format --check
    cd levee_auth && gleam format --check
    cd levee_admin && gleam format --check

check-format-elixir:
    mix format --check-formatted

# ─────────────────────────────────────────────────────────────────────────────
# Code Generation
# ─────────────────────────────────────────────────────────────────────────────

# Generate JSON schema from Gleam protocol types
generate-schema:
    mix generate_schema

# Generate schema and copy to TypeScript project
generate-schema-ts: generate-schema
    mkdir -p ../tools-monorepo/packages/levee-driver/schemas
    cp priv/protocol-schema.json ../tools-monorepo/packages/levee-driver/schemas/

# ─────────────────────────────────────────────────────────────────────────────
# Clean
# ─────────────────────────────────────────────────────────────────────────────

# Clean all build artifacts
clean: clean-gleam clean-elixir

clean-gleam:
    cd levee_protocol && rm -rf build
    cd levee_auth && rm -rf build
    cd levee_admin && rm -rf build

clean-elixir:
    mix clean
    rm -rf _build deps

# ─────────────────────────────────────────────────────────────────────────────
# CI Parity
# ─────────────────────────────────────────────────────────────────────────────

# Run PR checks
pr: check-format build test

# Run main branch checks
main: pr
