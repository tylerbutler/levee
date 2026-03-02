This is a web application built with Gleam (Wisp/Mist) and Elixir on the BEAM VM.

## Project guidelines

- The HTTP server is in `server/levee_web/` (Gleam, using Wisp for routing and Mist for HTTP)
- WebSocket channels are in `levee_channels/` (Gleam, using Beryl)
- Document session GenServers are in `server/lib/levee/documents/` (Elixir, loaded via FFI)
- Start the server with `just server` or `cd server/levee_web && gleam run`

### Gleam guidelines

- Use `Result` types for error handling, not panics
- Prefer pattern matching over conditional logic
- Use exhaustive pattern matching — the compiler will catch missed cases
- Follow the project's existing module naming conventions
- Gleam modules compile to Erlang/BEAM — call from Elixir using `:module_name` atom syntax

### Elixir guidelines (minimal — session GenServers only)

- Elixir code is limited to `server/lib/levee/documents/` (session.ex, registry.ex, supervisor.ex)
- These will eventually be ported to Gleam
- Use `start_supervised!/1` in tests for process cleanup
- Avoid `Process.sleep/1` in tests — use `Process.monitor/1` and assert on DOWN messages

### Testing

- Gleam tests use startest: `expect.to_equal`, `expect.to_be_ok`, etc.
- Elixir tests use ExUnit: `mix test`
- Run all tests: `just test`
