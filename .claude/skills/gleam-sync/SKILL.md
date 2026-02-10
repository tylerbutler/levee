---
name: gleam-sync
description: Rebuild Gleam protocol and reload Elixir modules
---

# Gleam Sync

Synchronize Gleam protocol changes with Elixir after modifying files in `levee_protocol/src/`.

## Quick Sync

```bash
cd levee_protocol && gleam build --target erlang && cd .. && mix compile --force
```

## Full Verification

After sync, verify the changes:

```bash
# Run Gleam tests
cd levee_protocol && gleam test

# Run Elixir tests that use the protocol
mix test test/levee/protocol/ test/levee/documents/
```

## When to Use

- After modifying any `.gleam` file in `levee_protocol/src/`
- After adding new Gleam dependencies
- When Elixir code reports "undefined function" for Gleam modules
- After `git pull` that includes Gleam changes

## Troubleshooting

If Elixir doesn't see Gleam changes:

```bash
# Clean rebuild
cd levee_protocol && gleam clean && gleam build --target erlang
cd .. && mix compile --force
```

If module not found errors persist:

```bash
# Check BEAM files exist
ls levee_protocol/build/dev/erlang/levee_protocol/ebin/*.beam
```
