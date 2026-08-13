# CLAUDE.md - @tylerbu/levee-driver

Package-specific guidance for the Levee Fluid Framework driver.

## Package Overview

Low-level Fluid Framework driver for connecting to Levee servers. This driver provides a drop-in replacement for Socket.IO-based drivers, using Phoenix Channels (Elixir/Phoenix) for real-time WebSocket communication.

**Status:** Published to npm as `@tylerbu/levee-driver`
**Framework:** `@fluidframework/*` deps pin `<2.100.0` (tested against 2.81.x); no exact version lock
**Purpose:** Personal projects using Fluid Framework with Phoenix/Elixir servers

See [DEV.md](DEV.md) for development workflows (e.g., updating protocol schema).

**Client compatibility strategy:** Per [ADR-004](../../../docs/adr/004-coexisting-client-stacks.md),
this driver remains the supported Phoenix Channels implementation for Levee.
Floodgate has a separate `@tylerbu/floodgate-client` package built on the
official Routerlicious driver. Share protocol-neutral fixtures and libraries
where useful, but do not couple the two transport implementations.

## Essential Commands

```bash
pnpm build          # Compile TypeScript
pnpm test:vitest    # Run tests
pnpm test:coverage  # Run tests with coverage
pnpm format         # Format code
pnpm lint           # Lint code
```

## Contributing Notes

- **Protocol changes:** Preserve compatibility with the Levee server and Fluid interfaces
- **Floodgate conformance:** Keep shared tests in `floodgate-contract.ts`, without treating this driver as temporary
- **Bug fixes and features:** Continue supporting the Phoenix Channels stack
- **Consumer docs:** See [README.md](README.md) for external developers
- **Strategy questions:** See [ADR-004](../../../docs/adr/004-coexisting-client-stacks.md)
