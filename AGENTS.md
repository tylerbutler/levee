This is a web application built with Gleam on the BEAM VM.

## Project guidelines

- The HTTP server is in `server/levee_web/` (Gleam, using Wisp for routing and Mist for HTTP)
- WebSocket channels are in `levee_channels/` (Gleam, using Beryl)
- Document sessions are in `server/levee_session/` (Gleam OTP actor)
- Start the server with `just server` or `cd server/levee_web && gleam run`

### Gleam guidelines

- Use `Result` types for error handling, not panics
- Prefer pattern matching over conditional logic
- Use exhaustive pattern matching — the compiler will catch missed cases
- Follow the project's existing module naming conventions
- Gleam modules compile to Erlang/BEAM bytecode

### Testing

- Gleam tests use startest: `expect.to_equal`, `expect.to_be_ok`, etc.
- Run all tests: `just test`
