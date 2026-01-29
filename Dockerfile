# Dockerfile for Levee server
# Multi-stage build for minimal production image

# Build stage
FROM elixir:1.18-otp-27-slim AS builder

# Install build dependencies including Gleam
RUN apt-get update && apt-get install -y --no-install-recommends \
    git build-essential curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install Gleam (required for levee_protocol)
ARG GLEAM_VERSION=1.9.1
RUN ARCH=$(uname -m) && \
    if [ "$ARCH" = "aarch64" ]; then \
      GLEAM_ARCH="aarch64-unknown-linux-musl"; \
    else \
      GLEAM_ARCH="x86_64-unknown-linux-musl"; \
    fi && \
    curl -fsSL https://github.com/gleam-lang/gleam/releases/download/v${GLEAM_VERSION}/gleam-v${GLEAM_VERSION}-${GLEAM_ARCH}.tar.gz \
    | tar -xzC /usr/local/bin

# Set build environment
ENV MIX_ENV=prod

WORKDIR /build

# Install hex and rebar first (cacheable layer)
RUN mix local.hex --force && \
    mix local.rebar --force

# Copy dependency files first for better caching
COPY mix.exs mix.lock ./
COPY levee_protocol/gleam.toml levee_protocol/manifest.toml levee_protocol/

# Install dependencies
RUN mix deps.get --only prod

# Copy the rest of the source
COPY config config
COPY lib lib
COPY priv priv
COPY levee_protocol levee_protocol

# Compile the application
RUN mix compile

# Build the release
RUN mix release

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
