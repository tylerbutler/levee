# CLAUDE.md - @tylerbu/levee-driver

Package-specific guidance for the Levee Fluid Framework driver.

## Package Overview

Low-level Fluid Framework driver for connecting to Levee servers. This driver provides a drop-in replacement for Socket.IO-based drivers, using Phoenix Channels (Elixir/Phoenix) for real-time WebSocket communication.

**Status:** Published to npm as `@tylerbu/levee-driver`
**Framework:** `@fluidframework/*` deps pin `<2.100.0` (tested against 2.81.x); no exact version lock
**Purpose:** Personal projects using Fluid Framework with Phoenix/Elixir servers

See [DEV.md](DEV.md) for development workflows (e.g., updating protocol schema).

**Client compatibility strategy:** Per [ADR-002](../../../docs/adr/002-client-compatibility-strategy.md),
the official `@fluidframework/routerlicious-driver` against Floodgate is the
long-term primary client path. This Phoenix Channels driver is legacy during
the migration and becomes deprecated once Floodgate passes
`test/integration/floodgate-routerlicious.test.ts` conformance for
create/load/sync/reconnect/summaries/signals. Do not add new Phoenix
Channels-only protocol features — new realtime behaviour should target the
Floodgate/Routerlicious contract (`test/integration/floodgate-contract.ts`) first.

## Essential Commands

```bash
pnpm build          # Compile TypeScript
pnpm test:vitest    # Run tests
pnpm test:coverage  # Run tests with coverage
pnpm format         # Format code
pnpm lint           # Lint code
```

## Contributing Notes

- **Protocol changes:** New Floodgate/Routerlicious features first via `floodgate-contract.ts`; Phoenix Channels is legacy
- **Bug fixes:** Continue; no new Phoenix-only features
- **Consumer docs:** See [README.md](README.md) for external developers
- **Strategy questions:** See [ADR-002](../../../docs/adr/002-client-compatibility-strategy.md)
