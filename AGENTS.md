This is a Fluid Framework–compatible collaborative document service. The
**server is pure Gleam** (Erlang target); the client packages are TypeScript.

There is **no Elixir/Phoenix** in this repo. Do not use `mix`, Ecto, LiveView,
or write `.ex`/`.exs` code on the server. Older Phoenix-era guidance has been
removed.

## Project guidelines

- Run `just build-server && just test-server` when you are done with all
  changes and fix any pending issues.
- For HTTP, use the Gleam HTTP stack already in use (`mist`/`wisp`,
  `gleam_http`). Do not introduce new HTTP frameworks.
- Server source lives under `server/`, one Gleam package per `gleam.toml`
  (`levee_server`, `levee_documents`, `levee_storage`, `levee_auth`,
  `levee_oauth`, `levee_protocol`, `levee_admin`).
- The front door is `levee_server` (mist + wisp routes, beryl WebSocket
  channels). Stateful document sessions live in `levee_documents` as
  `gleam_otp` actors.
- Minimal Erlang FFI is kept intentionally (`password_ffi.erl`,
  `storage_ffi_helpers.erl`, `tenant_secrets_ffi.erl`, `levee_server_ffi.erl`).
  Leave these in Erlang; don't port them unnecessarily.

## Gleam guidelines

- Each package is independent. Build/test one with `cd server/<package> &&
  gleam test`; build/test everything with `just build-server` / `just
  test-server`. Format with `just format-server`.
- `beryl`, `roost`, and `phoenix_channel_fixtures` are **git dependencies
  pinned to a ref** (not on Hex). `gleam add <pkg>` will fail for these — this
  is expected; don't switch them to Hex.
- After changing `levee_protocol` types that affect the wire schema, run
  `just generate-schema-ts` to regenerate and copy the schema to the client.
- Prefer `gleam_otp` primitives (actors, supervisors) for concurrency and
  process lifecycle.

## Wire compatibility (do not break)

The TypeScript client is unchanged and must keep working against the Gleam
server:

- Preserve the **Phoenix Channels JSON codec** (vsn 2.0.0) on
  `/socket/websocket`, topic `document:{tenant_id}:{document_id}`.
- Preserve **JWT** Bearer auth with scope checks on REST routes and the
  existing REST route shapes.
- **msgpack was intentionally dropped** — the server speaks JSON only. Do not
  add a msgpack codec back.

## Test guidelines

- Use `gleeunit` for server tests (`*_test.gleam` under each package's `test/`).
- To run a single package's tests: `cd server/<package> && gleam test`.
