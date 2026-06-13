# Copilot instructions for Levee

Levee is a Fluid Framework–compatible collaborative document service. The
**server is pure Gleam** (Erlang target); the client packages are TypeScript.

> ⚠️ Ignore any "Phoenix/Elixir/Mix" framing in older docs (e.g. parts of
> `AGENTS.md`). The Elixir/Phoenix server was fully removed — there is **no
> `mix`, Ecto, LiveView, or `.ex` code** in the server anymore. Do not
> reintroduce Elixir-based patterns or tooling.

## Architecture

Gleam server workspace under `server/`, one package per `gleam.toml`:

| Package | Purpose |
|---|---|
| `levee_server` | mist/wisp HTTP routes, beryl WebSocket channels, static/admin serving, app boot |
| `levee_documents` | Document session actor, registry, supervisor (gleam_otp) |
| `levee_storage` | Storage types, ETS/PostgreSQL backends |
| `levee_auth` | Users, tenants, sessions, JWT, scopes, password hashing |
| `levee_oauth` | OAuth provider config/state |
| `levee_protocol` | Fluid protocol types, sequencing, validation, schema CLI |
| `levee_admin` | Lustre admin SPA (JavaScript target) |

The front door is `levee_server` (mist + wisp + beryl). Stateful document
sessions live in `levee_documents` as `gleam_otp` actors. Minimal Erlang FFI is
kept intentionally (`password_ffi.erl`, `storage_ffi_helpers.erl`,
`tenant_secrets_ffi.erl`, `levee_server_ffi.erl`) — leave these in Erlang.

## Build, test, run

Use `just` recipes or per-package `gleam` — never `mix`:

```bash
just build-server          # build all Gleam server packages
just test-server           # run all server tests
cd server/levee_server && gleam run     # dev server on :4000
cd server/<package> && gleam test       # test a single package
just format-server         # format Gleam code
```

Each package is independent — to test or build just one, `cd` into its
directory. After protocol type changes affecting the schema, run
`just generate-schema-ts`.

### Dependency notes

`beryl`, `roost`, and `phoenix_channel_fixtures` are **git dependencies pinned
to a ref** (not published on Hex). `gleam add beryl` will fail — this is
expected; do not "fix" the pins by switching to Hex.

## Wire compatibility (do not break)

The TypeScript client is unchanged and must keep working against the Gleam
server. Preserve:

- **Phoenix Channels JSON codec** (vsn 2.0.0) for `/socket/websocket`,
  topic pattern `document:{tenant_id}:{document_id}`.
- **JWT** Bearer auth with scope checks (read/write/summary) on REST routes.
- The existing **REST route shapes** (`/documents/:tenant_id/...`,
  `/repos/:tenant_id/git/...`, `/refs/:tenant_id/...`).

**msgpack was intentionally dropped** — the server speaks JSON only. Do not add
a msgpack codec back.
