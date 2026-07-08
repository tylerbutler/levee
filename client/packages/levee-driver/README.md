# @tylerbu/levee-driver

Low-level Fluid Framework driver for connecting to Levee servers via Phoenix Channels.

> **Status:** This package is currently supported but is part of a planned migration to the official `@fluidframework/routerlicious-driver` against the Floodgate backend. See the [Client Compatibility Strategy](#client-compatibility-strategy) below.

## Quick Start

```typescript
import {
  LeveeDocumentServiceFactory,
  LeveeUrlResolver,
  InsecureLeveeTokenProvider,
} from "@tylerbu/levee-driver";
import { Loader } from "@fluidframework/container-loader";

// Create token provider (dev/test only)
const tokenProvider = new InsecureLeveeTokenProvider(
  "tenant-secret-key",
  { id: "user-123", name: "Test User" }
);

// Create URL resolver
const urlResolver = new LeveeUrlResolver(
  "ws://localhost:4000/socket",  // Phoenix WebSocket URL
  "http://localhost:4000"         // HTTP API URL
);

// Create document service factory
const serviceFactory = new LeveeDocumentServiceFactory(tokenProvider);

// Create loader and load/create containers
const loader = new Loader({
  urlResolver,
  documentServiceFactory: serviceFactory,
  codeLoader,
  logger,
});

// Load existing container
const container = await loader.resolve({ url: "fluid/my-document-id" });

// Create new container
const container = await loader.createDetachedContainer(codeDetails);
await container.attach(createNewRequest);
```

## Installation

```bash
npm install @tylerbu/levee-driver
# or
pnpm add @tylerbu/levee-driver
```

## API Reference

### LeveeUrlResolver

Creates URL resolver instances for Levee servers:

```typescript
new LeveeUrlResolver(
  socketUrl: string | undefined,  // Phoenix WebSocket URL. If omitted, derived
                                   // automatically from httpUrl (http→ws, https→wss)
  httpUrl: string,                 // HTTP API base URL (e.g., "http://localhost:4000")
  defaultTenantId?: string         // Default tenant ID when not present in the URL (default: "fluid")
)
```

### LeveeDocumentServiceFactory

Main entry point for the driver:

```typescript
new LeveeDocumentServiceFactory(
  tokenProvider: TokenProvider,
  debug?: boolean,                     // Enable debug logging (default: false)
  serialization?: "json" | "msgpack",  // WebSocket payload format (default: "json")
)
```

There is no separate `LeveeDeltaConnectionOptions` type — connection behavior is
configured through these factory constructor parameters. The maximum WebSocket
message size (`maxMessageSize`) defaults to 16KB (`16 * 1024`) and is negotiated
with the server at connection time; it is not a client-configurable option.

### Token Providers

#### InsecureLeveeTokenProvider

**⚠️ Development/test use only** — generates JWTs locally using a shared secret:

```typescript
new InsecureLeveeTokenProvider(
  tenantSecret: string,
  user: LeveeUser
)

interface LeveeUser {
  id: string;
  name: string;
}
```

#### RemoteLeveeTokenProvider

Production-safe token provider that fetches tokens from a remote auth service:

```typescript
new RemoteLeveeTokenProvider(
  tokenEndpoint: string,   // URL of the server's token-mint endpoint
  user?: LeveeUser,        // Optional — omit to resolve user identity server-side
  authToken?: string,      // Optional session/auth token sent to the token-mint endpoint
)
```

If `user` is omitted, call `resolveUser(tenantId)` after construction to fetch the
server-resolved user identity before using the provider with a Fluid loader.

## Component Architecture

```
LeveeDocumentServiceFactory (entry point)
    ├── LeveeDocumentService (per-document service)
    │   ├── LeveeStorageService (blob/snapshot operations)
    │   ├── LeveeDeltaStorageService (historical delta fetching)
    │   └── LeveeDeltaConnection (real-time WebSocket)
```

**LeveeStorageService** — Handles blob creation and snapshot fetching via HTTP

**LeveeDeltaStorageService** — Fetches historical deltas via HTTP REST API

**LeveeDeltaConnection** — Real-time bidirectional communication:
- Handles operation (op) submission and receipt
- Manages signal flow
- Provides early message buffering
- Handles connection lifecycle (connect, disconnect, reconnect)

## Protocol Mapping

This driver maps Fluid Framework operations to Phoenix Channel messages:

| Fluid Event | Phoenix Channel |
|-------------|-----------------|
| Connect document | `channel.push("connect_document")` |
| Submit operation | `channel.push("submitOp")` |
| Receive operation | `channel.on("op")` |
| Submit signal | `channel.push("submitSignal")` |
| Receive signal | `channel.on("signal")` |
| Negative acknowledgment | `channel.on("nack")` |
| Connection close | `channel.onClose()` |

## Testing

Run tests with:

```bash
pnpm test:vitest        # Run all tests
pnpm test:coverage      # Run with coverage
```

Integration tests require a running Levee server. See the test directory for examples.

## Client Compatibility Strategy

**This driver uses Phoenix Channels, which is temporary scaffolding during the Levee server migration to Floodgate.**

### Current State (2026)

- ✅ `levee-driver` is **fully supported** for Phoenix Channels-based Levee servers
- ✅ Use it in production if you're running the Phoenix-based Levee backend
- ✅ Bug fixes and reliability improvements continue

### Migration Path

Once the Floodgate backend reaches feature parity with the Routerlicious protocol (tracked in `test/integration/floodgate-routerlicious.test.ts`), you should migrate to:

```typescript
// After migration — use official Routerlicious driver
import { RouterliciousDocumentServiceFactory } from "@fluidframework/routerlicious-driver";

const serviceFactory = new RouterliciousDocumentServiceFactory(tokenProvider);
// ... point at Floodgate backend instead
```

### When Will This Happen?

- `levee-driver` becomes **deprecated** (marked in `package.json`) after Floodgate conformance is complete
- We'll provide a migration guide at that time
- Phoenix Channels support will transition to **legacy maintenance only** (security fixes, critical bugs)
- No new protocol features will be added to the Phoenix Channels driver

### For Now

**Use `@tylerbu/levee-client` if you want a higher-level API.** It's designed to remain compatible with the Routerlicious driver path after migration, so you'll have an easier upgrade path.

### See Also

- [ADR-002: Client compatibility strategy](../../../docs/adr/002-client-compatibility-strategy.md) — Full architectural decision
- [`floodgate-routerlicious.test.ts`](test/integration/floodgate-routerlicious.test.ts) — Conformance test suite
- `levee-client` — High-level convenience wrapper with migration-friendly design

## Troubleshooting

### Connection Issues

**WebSocket connection fails**
- Verify the `socketUrl` points to a valid Levee/Phoenix server with WebSocket support
- Check that the server is running on the correct host/port
- Verify firewall allows WebSocket connections

**"403 Unauthorized" when connecting**
- Ensure the token provider is generating valid JWTs
- Check that tenant IDs match between token and connection
- Verify the server has registered the tenant with the correct secret

### Protocol Errors

**"Unexpected message type"**
- The server may be incompatible with this driver version
- Check that the server is running a compatible Levee/Phoenix version
- Review the protocol schema in `schemas/protocol-schema.json`

### Performance

**High memory usage**
- The negotiated `maxMessageSize` (16KB default) is not client-configurable
- Monitor op buffer growth during disconnections
- Ensure you're not creating unbounded message queues

## Development

See [DEV.md](DEV.md) for:
- Updating protocol schema
- Building and testing locally
- Docker setup for local development

## Constraints

- **Fluid Framework** — `@fluidframework/*` dependencies pin to `<2.100.0` (currently tested against 2.81.x); no exact version lock
- **TypeScript 5.0+** (if using TypeScript)
- Requires a running Levee server with Phoenix 1.7+ or Floodgate backend
- No documented Node.js `engines` requirement in `package.json`; use an actively supported Node.js LTS release

## License

MIT

## Support

- Report bugs: [GitHub Issues](https://github.com/tylerbutler/levee/issues)
- Discuss architecture: See [ADR-002](../../../docs/adr/002-client-compatibility-strategy.md)
