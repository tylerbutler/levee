# CLAUDE.md - @tylerbu/levee-client

High-level client library wrapping `@tylerbu/levee-driver`.

**Status:** Published to npm as `@tylerbu/levee-client`  
**Framework:** `@fluidframework/*` deps pin `<2.100.0` (tested against 2.81.x); no exact version lock  
**Audience:** Agent guidance (consumer docs are in [README.md](README.md))

## Strategy Pointer

⚠️ **This client is a thin convenience layer designed to migrate to Routerlicious.**

See [ADR-002](../../../docs/adr/002-client-compatibility-strategy.md) for full context. Key points for contributors:

- Do **not** add new Phoenix Channels-specific API surface
- New high-level ergonomics should work with Routerlicious-backed service factories post-migration
- Keep the public API stable and re-pointable at the official client
- Bug fixes and reliability work continue; no new Phoenix-only features

## Essential Commands

```bash
pnpm build          # Compile TypeScript
pnpm test:vitest    # Run tests
pnpm test:coverage  # Run tests with coverage
pnpm format         # Format code
pnpm lint           # Lint code
```

## Contributing Notes

- **API surface:** Keep stable and re-pointable at official Routerlicious client post-migration
- **New features:** Target Routerlicious contract first; avoid Phoenix-only APIs
- **Bug fixes:** Continue; no new Phoenix-only protocol features
- **Consumer docs:** See [README.md](README.md) for external developers
- **Strategy questions:** See [ADR-002](../../../docs/adr/002-client-compatibility-strategy.md)
