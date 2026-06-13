# Dockerfile for the Gleam Levee server.

FROM erlang:28-slim AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential curl ca-certificates git \
    && rm -rf /var/lib/apt/lists/*

ARG GLEAM_VERSION=1.14.0
RUN ARCH=$(uname -m) && \
    if [ "$ARCH" = "aarch64" ]; then \
      GLEAM_ARCH="aarch64-unknown-linux-musl"; \
    else \
      GLEAM_ARCH="x86_64-unknown-linux-musl"; \
    fi && \
    curl -fsSL "https://github.com/gleam-lang/gleam/releases/download/v${GLEAM_VERSION}/gleam-v${GLEAM_VERSION}-${GLEAM_ARCH}.tar.gz" \
    | tar -xzC /usr/local/bin

ARG JUST_VERSION=1.40.0
RUN ARCH=$(uname -m) && \
    if [ "$ARCH" = "aarch64" ]; then \
      JUST_ARCH="aarch64-unknown-linux-musl"; \
    else \
      JUST_ARCH="x86_64-unknown-linux-musl"; \
    fi && \
    curl -fsSL "https://github.com/casey/just/releases/download/${JUST_VERSION}/just-${JUST_VERSION}-${JUST_ARCH}.tar.gz" \
    | tar -xzC /usr/local/bin

WORKDIR /build

COPY justfile ./
COPY levee_protocol/gleam.toml levee_protocol/manifest.toml levee_protocol/
COPY levee_auth/gleam.toml levee_auth/manifest.toml levee_auth/
COPY levee_storage/gleam.toml levee_storage/manifest.toml levee_storage/
COPY levee_oauth/gleam.toml levee_oauth/manifest.toml levee_oauth/
COPY levee_documents/gleam.toml levee_documents/manifest.toml levee_documents/
COPY levee_server/gleam.toml levee_server/manifest.toml levee_server/
COPY levee_admin/gleam.toml levee_admin/manifest.toml levee_admin/
RUN just setup-gleam

COPY levee_protocol levee_protocol
COPY levee_auth levee_auth
COPY levee_storage levee_storage
COPY levee_oauth levee_oauth
COPY levee_documents levee_documents
COPY levee_server levee_server
COPY levee_admin levee_admin
COPY priv priv

RUN just build-admin && cd levee_server && gleam export erlang-shipment

FROM erlang:28-slim AS runtime

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates wget openssl libstdc++6 libncurses6 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=builder /build/levee_server/build/erlang-shipment ./
COPY --from=builder /build/priv ./priv

ENV PORT=4000
ENV LEVEE_TENANT_ID=fluid
ENV LEVEE_TENANT_KEY=dev-tenant-secret-key

EXPOSE 4000

HEALTHCHECK --interval=5s --timeout=3s --start-period=15s --retries=3 \
    CMD wget --no-verbose --tries=1 --spider http://localhost:4000/health || exit 1

CMD ["./entrypoint.sh", "run"]
