# @tylerbu/levee-client

High-level Fluid Framework client for connecting to Levee servers.

> **Status:** Supported high-level client for the Levee/Phoenix server stack. Floodgate uses the separate `@tylerbu/floodgate-client` package.

## Quick Start

```typescript
import { LeveeClient } from "@tylerbu/levee-client";
import type { ContainerSchema } from "fluid-framework";
import { SharedMap } from "@fluidframework/map";

const client = new LeveeClient({
  connection: {
    httpUrl: "http://localhost:4000",
    socketUrl: "ws://localhost:4000/socket",
    tenantKey: "dev-secret-key", // dev/test only
    user: {
      id: "user-123",
      name: "Test User",
    },
  },
});

// Create a new container
const containerSchema = {
  initialObjects: {
    myMap: SharedMap,
  },
} satisfies ContainerSchema;

const { container } = await client.createContainer(containerSchema, "2");
const containerId = await container.attach();

// Load an existing container
const { container: loaded } = await client.getContainer(
  containerId,
  containerSchema,
  "2"
);
```

## Installation

```bash
npm install @tylerbu/levee-client
# or
pnpm add @tylerbu/levee-client
```

## API Reference

### LeveeClient

Main client class for creating and loading containers:

```typescript
const client = new LeveeClient(properties: LeveeClientProps);
```

There is also an async factory, `LeveeClient.create(properties)`, for the case
where you provide `authToken` without `user` — it resolves the user identity
from the server's token-mint endpoint before constructing the client:

```typescript
const client = await LeveeClient.create({
  connection: {
    httpUrl: "https://levee.example.com",
    socketUrl: "wss://levee.example.com/socket",
    authToken: sessionToken,
  },
});
```

#### Properties

```typescript
interface LeveeClientProps {
  /** Configuration for establishing a connection with the Levee server. */
  readonly connection: LeveeConnectionConfig;

  /** Optional. A logger instance to receive diagnostic messages. */
  readonly logger?: ITelemetryBaseLogger;
}

interface LeveeConnectionConfig {
  /** HTTP base URL for REST API (e.g., "http://localhost:4000"). */
  readonly httpUrl: string;

  /**
   * WebSocket URL for Phoenix socket (e.g., "ws://localhost:4000/socket").
   * Optional — derived automatically from httpUrl if not provided
   * (http → ws, https → wss).
   */
  readonly socketUrl?: string;

  /** Tenant ID (defaults to "fluid"). */
  readonly tenantId?: string;

  /**
   * Tenant secret key for InsecureLeveeTokenProvider (dev only).
   * If provided, creates an InsecureLeveeTokenProvider automatically.
   * Ignored if tokenProvider is specified.
   */
  readonly tenantKey?: string;

  /**
   * User information for token generation and audience identification.
   * Required when using `tenantKey` or a custom `tokenProvider`.
   * Optional when using `authToken` — user identity will be resolved
   * from the server via the token-mint endpoint.
   */
  readonly user?: LeveeUser;

  /**
   * Authentication token (e.g., session token from OAuth login).
   * When provided without a custom `tokenProvider`, the client automatically
   * creates a RemoteLeveeTokenProvider that sends this token to the Levee
   * token-mint endpoint (`${httpUrl}/api/tenants/${tenantId}/token-mint`).
   */
  readonly authToken?: string;

  /** Custom token provider (overrides tenantKey and authToken if provided). */
  readonly tokenProvider?: TokenProvider;
}

interface LeveeUser {
  id: string;
  name: string;
}
```

`LeveeClient` requires at least one of `user` or `authToken` in `connection`
(the constructor throws otherwise), and one of `tokenProvider`, `tenantKey`, or
`authToken` to establish a token provider.

### Container Creation

```typescript
async createContainer<TContainerSchema extends ContainerSchema>(
  containerSchema: TContainerSchema,
  compatibilityMode: CompatibilityMode
): Promise<{
  container: IFluidContainer<TContainerSchema>;
  services: LeveeContainerServices;
}>
```

`CompatibilityMode` is `"1" | "2"` (re-exported from `@fluidframework/fluid-static`).
Use `"2"` unless you have a specific reason to target the legacy `"1"` runtime
options.

Creates a new detached container. Call `container.attach()` to persist it.

### Container Loading

```typescript
async getContainer<TContainerSchema extends ContainerSchema>(
  id: string,
  containerSchema: TContainerSchema,
  compatibilityMode: CompatibilityMode
): Promise<{
  container: IFluidContainer<TContainerSchema>;
  services: LeveeContainerServices;
}>
```

Loads an existing container by ID.

### Services

The returned `services` object provides access to Fluid Framework services:

```typescript
const { services } = await client.getContainer(containerId, schema, "2");

// Access audience (connected users)
const members = services.audience.getMembers();

// Listen to audience changes
services.audience.on("membersChanged", () => {
  console.log("Members changed");
});
```

### Token Providers

#### Development (InsecureLeveeTokenProvider)

⚠️ **Development/test use only**:

```typescript
const client = new LeveeClient({
  connection: {
    // ... other config
    tenantKey: "dev-secret", // Local JWT generation
  },
});
```

#### Production (RemoteLeveeTokenProvider)

`RemoteLeveeTokenProvider` fetches tokens from a remote endpoint; it is not
callback-based. Pass an `authToken` and the client constructs the provider for
you automatically:

```typescript
const client = await LeveeClient.create({
  connection: {
    httpUrl: "https://levee.example.com",
    socketUrl: "wss://levee.example.com/socket",
    authToken: sessionToken, // sent to the token-mint endpoint
  },
});
```

Or construct it directly from `@tylerbu/levee-driver` if you need finer control:

```typescript
import { RemoteLeveeTokenProvider } from "@tylerbu/levee-driver";

const tokenProvider = new RemoteLeveeTokenProvider(
  "https://levee.example.com/api/tenants/fluid/token-mint",
  { id: "user-123", name: "Test User" }, // optional; omit to resolve server-side
  sessionToken, // optional auth token
);

const client = new LeveeClient({
  connection: {
    httpUrl: "https://levee.example.com",
    socketUrl: "wss://levee.example.com/socket",
    user: { id: "user-123", name: "Test User" },
    tokenProvider,
  },
});
```

## Examples

### Basic DiceRoller

```typescript
import { LeveeClient } from "@tylerbu/levee-client";
import { SharedMap } from "@fluidframework/map";
import { Counter } from "@fluidframework/counter";
import type { ContainerSchema } from "fluid-framework";

const schema = {
  initialObjects: {
    diceValues: SharedMap,
    rollCount: Counter,
  },
} satisfies ContainerSchema;

const client = new LeveeClient({
  connection: {
    httpUrl: "http://localhost:4000",
    socketUrl: "ws://localhost:4000/socket",
    tenantKey: "dev-secret",
    user: { id: "player-1", name: "Player 1" },
  },
});

// Create
const { container } = await client.createContainer(schema, "2");
const containerId = await container.attach();

// Interact with shared objects
container.initialObjects.diceValues.set("result", Math.floor(Math.random() * 6) + 1);
container.initialObjects.rollCount.increment();

// Load (in another session)
const { container: loaded } = await client.getContainer(containerId, schema, "2");
console.log(loaded.initialObjects.diceValues.get("result")); // Rolls from all players
```

### With Presence Tracking

See `@tylerbu/levee-presence-tracker` for a complete example of presence-aware collaboration.

## Testing

Run tests:

```bash
pnpm test:vitest        # Run all tests
pnpm test:coverage      # Run with coverage
```

Integration tests require a running Levee server.

## Architecture

LeveeClient wraps the lower-level `@tylerbu/levee-driver` components:

```
LeveeClient (this package — high-level API)
    └── LeveeDocumentServiceFactory (from levee-driver)
        ├── LeveeDocumentService
        │   ├── LeveeStorageService
        │   ├── LeveeDeltaStorageService
        │   └── LeveeDeltaConnection (Phoenix Channels)
```

Use `@tylerbu/levee-driver` directly if you need:
- Custom container loading with the Fluid Loader API
- Direct access to document service factory
- Custom URL resolvers or token providers

## Client Compatibility Strategy

**This client is the supported high-level API for the Levee/Phoenix stack.**

### Current State (2026)

- ✅ `levee-client` is **fully supported** for Phoenix Channels-based Levee servers
- ✅ Use it in production if you're running the Phoenix-based Levee backend
- ✅ Bug fixes and reliability improvements continue

### Floodgate Alternative

Floodgate is a separate Gleam server stack using the official Routerlicious
driver. Its independent, release-ready client package is available through the
same client release pipeline:

```typescript
import { createFloodgateClientAdapter } from "@tylerbu/floodgate-client";

const floodgate = createFloodgateClientAdapter({
  httpUrl: "https://floodgate.example.com",
  tenantId: "fluid",
  tokenProvider,
});
```

The two packages may share familiar container lifecycle conventions, but
neither server stack replaces the other.

### See Also

- [ADR-004: Coexisting client stacks](../../../docs/adr/004-coexisting-client-stacks.md) — Current architectural decision
- [`floodgate-routerlicious.test.ts`](../levee-driver/test/integration/floodgate-routerlicious.test.ts) — Conformance test suite
- `@tylerbu/levee-driver` — Lower-level driver documentation
- `@tylerbu/floodgate-client` — Floodgate/Routerlicious client package

## Important Constraints

1. **Published Package** - Published to npm as `@tylerbu/levee-client`
2. **Fluid Framework Version** - `@fluidframework/*` dependencies pin to `<2.100.0` (currently tested against 2.81.x); no exact version lock
3. **TypeScript** - Strict mode enabled
4. **Levee Server** - Requires running Phoenix/Elixir Levee server
5. **Biome Formatting** - Code must pass Biome checks

## Related Packages

- [`@tylerbu/levee-driver`](../levee-driver/README.md) — Lower-level driver (use if you need Fluid Loader API)
- [`@tylerbu/levee-example`](../levee-example) — DiceRoller example using driver directly
- [`@tylerbu/levee-presence-tracker`](../levee-presence-tracker) — Presence tracking example using this client

## Troubleshooting

### Connection Issues

**Failed to connect to server**
- Verify `httpUrl` and `socketUrl` are correct
- Check that the Levee server is running
- Verify firewall allows WebSocket connections

**"Unauthorized" errors**
- Check that `tenantKey` matches the server's registered tenant
- Verify the token provider is generating valid tokens
- Ensure tenant IDs match between client and server

### Container Operations

**Container not persisting**
- Ensure you call `container.attach()` after creating a new container
- Verify the server has write permissions
- Check that the operation completes before closing the connection

## Fluid Framework Resources

**Official Documentation:**
- https://fluidframework.com/docs/
- https://github.com/microsoft/FluidFramework

**Key Concepts:**
- Distributed Data Structures (DDSes)
- Container lifecycle
- fluid-static API patterns
- Token providers

## License

MIT

## Support

- Report bugs: [GitHub Issues](https://github.com/tylerbutler/levee/issues)
- Discuss architecture: See [ADR-004](../../../docs/adr/004-coexisting-client-stacks.md)
