# Dockerfile for Levee server
# Multi-stage build for minimal production image

# Build stage
FROM elixir:1.18-otp-27-slim AS builder

# Install build dependencies including Gleam and just
RUN apt-get update && apt-get install -y --no-install-recommends \
    git build-essential curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install Gleam (required for levee_protocol, levee_auth, levee_admin)
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
COPY justfile ./
COPY mix.exs mix.lock ./
COPY levee_protocol/gleam.toml levee_protocol/manifest.toml levee_protocol/
COPY levee_auth/gleam.toml levee_auth/manifest.toml levee_auth/
COPY levee_storage/gleam.toml levee_storage/manifest.toml levee_storage/
COPY levee_oauth/gleam.toml levee_oauth/manifest.toml levee_oauth/

# Install Elixir dependencies
RUN mix deps.get --only prod

# Copy all source files
COPY levee_protocol levee_protocol
COPY levee_auth levee_auth
COPY levee_storage levee_storage
COPY levee_oauth levee_oauth
COPY levee_admin levee_admin
COPY config config
COPY lib lib
COPY priv priv
COPY rel rel

# Build everything and create the release
RUN just release

# Runtime stage
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
# Copy all ebin dirs for each Gleam package and their dependencies
COPY --from=builder /build/levee_protocol/build/dev/erlang/ ./levee_protocol/build/dev/erlang/
COPY --from=builder /build/levee_auth/build/dev/erlang/ ./levee_auth/build/dev/erlang/
COPY --from=builder /build/levee_storage/build/dev/erlang/ ./levee_storage/build/dev/erlang/
COPY --from=builder /build/levee_oauth/build/dev/erlang/ ./levee_oauth/build/dev/erlang/

# Set runtime environment
ENV MIX_ENV=prod
ENV PHX_SERVER=true
ENV PHX_HOST=localhost
ENV PORT=4000

# Expose the Phoenix port
EXPOSE 4000

# Health check
HEALTHCHECK --interval=5s --timeout=3s --start-period=15s --retries=3 \
    CMD wget --no-verbose --tries=1 --spider http://localhost:4000/health || exit 1

# Start the server
CMD ["bin/levee", "start"]
