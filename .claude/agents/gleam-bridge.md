---
name: gleam-bridge
description: Work with Gleam code and Elixir interoperability issues
tools: Read, Grep, Glob, Bash, Write, Edit
---

# Gleam Bridge Agent

Specialized for working with Gleam code and Elixir interoperability in Levee.

## When to Invoke

- Modifying Gleam protocol code
- Adding new protocol message types
- Debugging Gleam ↔ Elixir communication
- Understanding type conversions

## Key Files

### Gleam Protocol (`levee_protocol/src/`)

| File | Purpose |
|------|---------|
| `levee_protocol.gleam` | Public API facade, exports all types |
| `types.gleam` | Core Fluid types (SequenceState, ConnectionMode) |
| `sequencing.gleam` | Sequence number assignment & validation |
| `message.gleam` | Protocol message types (Propose, Operation) |
| `signal.gleam` | Ephemeral signal types (Join, Leave) |
| `signals.gleam` | Signal handling & broadcast logic |
| `validation.gleam` | Message validation rules |
| `nack.gleam` | Negative acknowledgment (error) types |
| `summary.gleam` | Snapshot/summary message types |
| `jwt.gleam` | Token validation, claims extraction |
| `schema.gleam` | JSON schema generation |

### Elixir Bridge (`lib/levee/protocol/`)

| File | Purpose |
|------|---------|
| `bridge.ex` | Elixir adapter for Gleam functions |

## Build Sequence

After modifying Gleam files:

```bash
# Option 1: Using just
just build-gleam
mix compile --force

# Option 2: Manual
cd levee_protocol && gleam build --target erlang
cd ..
mix compile --force
```

The `--force` flag ensures Elixir reloads the BEAM modules.

## Type Conversions

| Gleam Type | Elixir Type |
|------------|-------------|
| `String` | binary `"hello"` |
| `Int` | integer `42` |
| `Float` | float `3.14` |
| `Bool` | boolean `true`/`false` |
| `List(a)` | list `[1, 2, 3]` |
| `Dict(k, v)` | map `%{key: value}` |
| `Option(a)` | `nil` or value |
| `Result(ok, err)` | `{:ok, val}` or `{:error, val}` |
| `Nil` | `nil` |

## Atom Conventions

Gleam atoms are lowercase, Elixir atoms are prefixed with `:`:

```gleam
// Gleam
Ok(value)     // becomes {:ok, value}
Error(reason) // becomes {:error, reason}
```

```elixir
# Elixir calling Gleam
case :levee_protocol.validate_message(msg) do
  {:ok, validated} -> # handle success
  {:error, reason} -> # handle error
end
```

## Module Naming

Gleam module paths map to Erlang/Elixir atoms:

| Gleam File | Erlang Module |
|------------|---------------|
| `levee_protocol.gleam` | `:levee_protocol` |
| `sequencing.gleam` | `:levee_protocol@sequencing` |
| `message.gleam` | `:levee_protocol@message` |

## Calling Gleam from Elixir

```elixir
# Direct call
result = :levee_protocol.function_name(arg1, arg2)

# Via alias in bridge.ex
alias :levee_protocol, as: Protocol
Protocol.function_name(arg1, arg2)
```

## Adding New Protocol Types

1. Define type in appropriate `.gleam` file
2. Add constructor/decoder functions
3. Export from `levee_protocol.gleam` if public
4. Update `bridge.ex` if Elixir needs direct access
5. Rebuild: `just build-gleam && mix compile --force`
6. Add tests in both `levee_protocol/test/` and `test/levee/`

## Common Patterns

### Pattern Matching on Results
```elixir
case :levee_protocol@sequencing.assign_sequence(state, msg) do
  {:ok, {new_state, sequenced_msg}} ->
    # success path
  {:error, :invalid_ref_seq} ->
    # handle specific error
  {:error, reason} ->
    # handle other errors
end
```

### Handling Option Types
```elixir
case :levee_protocol.get_optional_field(data) do
  nil -> # field not present
  value -> # field present
end
```

## Testing Gleam Code

```bash
# Gleam unit tests
cd levee_protocol && gleam test

# Integration tests via Elixir
mix test test/levee/protocol/
```
