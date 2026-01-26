# Fluid Server - Elixir + Gleam
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
    cd gleam_protocol && gleam deps download

# Install Elixir dependencies
setup-elixir:
    mix deps.get

# ─────────────────────────────────────────────────────────────────────────────
# Build
# ─────────────────────────────────────────────────────────────────────────────

# Build everything
build: build-gleam build-elixir

# Build Gleam package
build-gleam:
    cd gleam_protocol && gleam build --target erlang

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
    cd gleam_protocol && gleam test

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
    cd gleam_protocol && gleam format

# Format Elixir code
format-elixir:
    mix format

# Check formatting
check-format: check-format-gleam check-format-elixir

check-format-gleam:
    cd gleam_protocol && gleam format --check

check-format-elixir:
    mix format --check-formatted

# ─────────────────────────────────────────────────────────────────────────────
# Clean
# ─────────────────────────────────────────────────────────────────────────────

# Clean all build artifacts
clean: clean-gleam clean-elixir

clean-gleam:
    cd gleam_protocol && rm -rf build

clean-elixir:
    mix clean
    rm -rf _build deps
