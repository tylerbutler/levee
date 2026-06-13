# Levee Architecture

Levee is a Fluid Framework-compatible collaborative document service with a pure Gleam server and TypeScript client packages.

## Components

1. **Gleam server** (`server/levee_server`) — Mist/Wisp HTTP routes, Beryl Phoenix Channels-compatible WebSockets, static/admin serving, and OTP boot.
2. **Domain packages** — `levee_protocol`, `levee_auth`, `levee_storage`, `levee_oauth`, and `levee_documents`.
3. **Client packages** — `levee-driver`, `levee-client`, and examples built with TypeScript and Fluid Framework.
4. **Admin UI** — `levee_admin`, a Lustre app compiled to JavaScript and served from `server/priv/static/admin`.

## Request Flow

```text
TypeScript client
  ├─ REST → Mist/Wisp routes → auth/scope checks → storage or document actors
  └─ WS   → Beryl channel  → document session actor → storage/broadcasts
```

All server runtime code is Gleam on the BEAM. The remaining `.erl` files are small FFI helpers for OTP/runtime operations that Gleam does not expose directly.

## Server Package Responsibilities

| Package | Responsibility |
|---|---|
| `levee_server` | App boot, routing, channels, CORS, static assets, Docker shipment entry |
| `levee_documents` | Document sessions, registry, supervisors, tenant secrets integration |
| `levee_storage` | ETS and PostgreSQL persistence for documents, deltas, git objects, refs, summaries |
| `levee_auth` | Users, tenants, sessions, JWTs, scopes, password hashing |
| `levee_oauth` | OAuth config, providers, state and PKCE support |
| `levee_protocol` | Fluid wire types, sequencing, validation, schema generation |
| `levee_admin` | Browser admin UI |

## Storage

The storage package exposes typed Gleam APIs over ETS and PostgreSQL backends. Data remains tenant-scoped using `{tenant_id, document_id}` keys where applicable. Development defaults to ETS-backed storage; PostgreSQL tests use `DATABASE_URL`.

## Realtime Protocol

The client still speaks a Phoenix Channels-compatible protocol. The server compatibility layer is implemented in Gleam with Beryl, so no Phoenix runtime is required.

## Build and Run

```bash
just build-server
just test-server
just server
```

`just generate-schema-ts` runs the Gleam protocol schema CLI and copies the JSON schema into the TypeScript driver package.
