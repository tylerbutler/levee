# CLAUDE.md - @tylerbu/levee-client

High-level client library wrapping `@tylerbu/levee-driver`.

**Status:** Published to npm as `@tylerbu/levee-client`  
**Framework:** `@fluidframework/*` deps pin `<2.100.0` (tested against 2.81.x); no exact version lock  
**Audience:** Agent guidance (consumer docs are in [README.md](README.md))

## Strategy Pointer

**This client is the high-level API for the Levee/Phoenix server stack.**

See [ADR-004](../../../docs/adr/004-coexisting-client-stacks.md) for full context. Key points for contributors:

- Levee and Floodgate coexist as independent server implementations
- Keep this package focused on Levee and `@tylerbu/levee-driver`
- Put official Routerlicious/Floodgate integration in `@tylerbu/floodgate-client`
- Preserve the public API and support stack-specific Levee capabilities where useful

## Essential Commands

```bash
pnpm build          # Compile TypeScript
pnpm test:vitest    # Run tests
pnpm test:coverage  # Run tests with coverage
pnpm format         # Format code
pnpm lint           # Lint code
```

## Contributing Notes

- **API surface:** Keep stable for Levee consumers
- **New features:** Implement Levee/Phoenix features here; share protocol-neutral code when practical
- **Floodgate features:** Implement in `@tylerbu/floodgate-client`
- **Consumer docs:** See [README.md](README.md) for external developers
- **Strategy questions:** See [ADR-004](../../../docs/adr/004-coexisting-client-stacks.md)
