# Dockerfile for Levee server + Sandbag testing hub
# Multi-stage build: Node.js (client) → Elixir/Gleam (server) → minimal runtime

# === Stage 1: Build client packages and Sandbag static site ===
FROM node:22-slim AS node-builder

WORKDIR /build

# Enable pnpm via corepack
RUN corepack enable && corepack prepare pnpm@10.24.0 --activate

# Copy client workspace
COPY client/ ./

# Install deps, build TypeScript packages, then build Sandbag SvelteKit app
RUN pnpm install --frozen-lockfile && pnpm build && cd packages/sandbag && pnpm build

# === Stage 2: Build Elixir/Gleam server ===
FROM elixir:1.18-otp-27-slim AS builder

# Install build dependencies including Gleam and just
RUN apt-get update && apt-get install -y --no-install-recommends \
    git build-essential curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install Gleam (required for levee_protocol, levee_auth, levee_storage, levee_oauth)
ARG GLEAM_VERSION=1.14.0
RUN ARCH=$(uname -m) && \
    if [ "$ARCH" = "aarch64" ]; then \
      GLEAM_ARCH="aarch64-unknown-linux-musl"; \
    else \
      GLEAM_ARCH="x86_64-unknown-linux-musl"; \
    fi && \
    curl -fsSL https://github.com/gleam-lang/gleam/releases/download/v${GLEAM_VERSION}/gleam-v${GLEAM_VERSION}-${GLEAM_ARCH}.tar.gz \
    | tar -xzC /usr/local/bin

# Install just
ARG JUST_VERSION=1.40.0
RUN ARCH=$(uname -m) && \
    if [ "$ARCH" = "aarch64" ]; then \
      JUST_ARCH="aarch64-unknown-linux-musl"; \
    else \
      JUST_ARCH="x86_64-unknown-linux-musl"; \
    fi && \
    curl -fsSL https://github.com/casey/just/releases/download/${JUST_VERSION}/just-${JUST_VERSION}-${JUST_ARCH}.tar.gz \
    | tar -xzC /usr/local/bin

# Set build environment
ENV MIX_ENV=prod

WORKDIR /build

# Install hex and rebar first (cacheable layer)
RUN mix local.hex --force && \
    mix local.rebar --force

# Copy justfile and dependency files first for better caching
COPY server/justfile ./justfile
COPY server/mix.exs server/mix.lock ./
COPY server/levee_protocol/gleam.toml server/levee_protocol/manifest.toml levee_protocol/
COPY server/levee_auth/gleam.toml server/levee_auth/manifest.toml levee_auth/
COPY server/levee_storage/gleam.toml server/levee_storage/manifest.toml levee_storage/
COPY server/levee_oauth/gleam.toml server/levee_oauth/manifest.toml levee_oauth/

# Install Elixir dependencies
RUN mix deps.get --only prod

# Copy all server source files
COPY server/levee_protocol levee_protocol
COPY server/levee_auth levee_auth
COPY server/levee_storage levee_storage
COPY server/levee_oauth levee_oauth
COPY server/levee_admin levee_admin
COPY server/config config
COPY server/lib lib
COPY server/priv priv
COPY server/rel rel

# Copy Sandbag static build from node-builder stage
COPY --from=node-builder /build/packages/sandbag/build/ priv/static/sandbag/

# Build everything and create the release
RUN just release

# === Stage 3: Runtime ===
FROM debian:bookworm-slim AS runtime

# Install runtime dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    libstdc++6 openssl libncurses6 locales ca-certificates wget \
    && rm -rf /var/lib/apt/lists/* \
    && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8

WORKDIR /app

# Copy the release from builder
COPY --from=builder /build/_build/prod/rel/levee ./

# Copy Gleam compiled modules (required at runtime)
COPY --from=builder /build/levee_protocol/build/dev/erlang/ ./levee_protocol/build/dev/erlang/
COPY --from=builder /build/levee_auth/build/dev/erlang/ ./levee_auth/build/dev/erlang/
COPY --from=builder /build/levee_storage/build/dev/erlang/ ./levee_storage/build/dev/erlang/
COPY --from=builder /build/levee_oauth/build/dev/erlang/ ./levee_oauth/build/dev/erlang/

# Set runtime environment with self-contained defaults
ENV MIX_ENV=prod
ENV PHX_SERVER=true
ENV PHX_HOST=localhost
ENV PORT=4000
ENV SECRET_KEY_BASE=dev-only-secret-key-base-at-least-64-characters-long-for-phoenix-framework

# Tenant configuration
ENV LEVEE_TENANT_ID=sandbag
ENV LEVEE_TENANT_KEY=dev-tenant-secret-key

# GitHub OAuth (test app, localhost only)
ENV GITHUB_CLIENT_ID=Ov23liFOkdUgDr9ebwRc
ENV GITHUB_CLIENT_SECRET=b09502196507f2b76f5ba3f9161c7862e7737c90
ENV GITHUB_REDIRECT_URI=http://127.0.0.1:4000/auth/github/callback

# Expose the Phoenix port
EXPOSE 4000

# Health check
HEALTHCHECK --interval=5s --timeout=3s --start-period=15s --retries=3 \
    CMD wget --no-verbose --tries=1 --spider http://localhost:4000/health || exit 1

# Start the server
CMD ["bin/levee", "start"]
