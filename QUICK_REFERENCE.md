# FluidFramework Public API - Quick Reference Card

## Client Creation

### AzureClient
```typescript
import { AzureClient } from "@fluidframework/azure-client";

const client = new AzureClient({
  connection: {
    type: "remote",  // or "local"
    endpoint: "https://api.fluidrelay.azure.com",
    tenantId: "my-tenant-id",
    tokenProvider: myTokenProvider,
  },
});
```

### TinyliciousClient
```typescript
import { TinyliciousClient } from "@fluidframework/tinylicious-client";

const client = new TinyliciousClient();
// or with custom config:
// const client = new TinyliciousClient({
//   connection: { port: 7070, domain: "localhost" }
// });
```

---

## Creating & Loading Containers

```typescript
// Define schema
const schema: ContainerSchema = {
  initialObjects: {
    myMap: SharedMap,
    myString: SharedString,
  },
  dynamicObjectTypes: [SharedMap, SharedString],
};

// Create new container
const { container, services } = await client.createContainer(schema, "2");
const containerId = await container.attach();  // Returns container ID

// Load existing container
const { container, services } = await client.getContainer(
  containerId,
  schema,
  "2"
);

// View container version (Azure only)
const { container } = await client.viewContainerVersion(
  containerId,
  schema,
  { id: "version-1" },
  "2"
);
```

---

## Container State & Lifecycle

```typescript
// Check states
if (container.connectionState === "Connected") { }
if (container.isDirty) { console.log("Has unsaved changes"); }
if (container.disposed) { console.log("Container closed"); }
if (container.attachState === "Attached") { }

// Access initial data
const myMap = container.initialObjects.myMap;  // Typed access
myMap.set("key", "value");

// Create dynamic objects
const newMap = await container.create(SharedMap);

// Connection control
container.connect();      // From Disconnected
container.disconnect();   // From Connected
await container.dispose();  // Close permanently
```

---

## Container Events

```typescript
container.on("connected", () => {
  console.log("Connected to service");
});

container.on("disconnected", () => {
  console.log("Lost connection");
});

container.on("dirty", () => {
  console.log("You have unsaved changes!");
});

container.on("saved", () => {
  console.log("All changes saved");
});

container.on("disposed", (error) => {
  if (error) console.error("Closed due to error:", error);
  else console.log("Closed normally");
});
```

---

## Audience (Collaboration)

```typescript
const { audience } = services;

// Get all current users
const members = audience.getMembers();
for (const [userId, member] of members) {
  console.log(`${member.id}: ${member.name} (${member.connections.length} tabs)`);
}

// Get self
const myself = audience.getMyself();
if (myself) {
  console.log(`I am ${myself.name}, connection: ${myself.currentConnection}`);
}

// Listen for changes
audience.on("memberAdded", (clientId, member) => {
  console.log(`${member.name} joined`);
});

audience.on("memberRemoved", (clientId, member) => {
  console.log(`${member.name} left`);
});

audience.on("membersChanged", () => {
  console.log("Roster updated:", audience.getMembers().size);
});
```

---

## Token Provider Implementation

```typescript
class MyTokenProvider implements ITokenProvider {
  async fetchOrdererToken(
    tenantId: string,
    documentId?: string,
    refresh?: boolean
  ): Promise<ITokenResponse> {
    const token = await getTokenFromAuthService(
      tenantId,
      documentId,
      refresh
    );
    return {
      jwt: token,
      fromCache: !refresh,
    };
  }

  async fetchStorageToken(
    tenantId: string,
    documentId: string,
    refresh?: boolean
  ): Promise<ITokenResponse> {
    // Same as fetchOrdererToken for most implementations
    return this.fetchOrdererToken(tenantId, documentId, refresh);
  }

  async documentPostCreateCallback?(
    documentId: string,
    creationToken: string
  ): Promise<void> {
    // Optional: verify document creator
    await verifyCreator(documentId, creationToken);
  }
}
```

---

## Type Definitions Summary

```typescript
// Container schema - define once
type MySchema = {
  readonly initialObjects: {
    readonly myMap: SharedMap;
    readonly myString: SharedString;
  };
  readonly dynamicObjectTypes: readonly [SharedMap, SharedString];
};

// Container - strongly typed
type MyContainer = IFluidContainer<MySchema>;

// Access with type safety
const value = container.initialObjects.myMap;  // Type: SharedMap
const value = container.initialObjects.myString;  // Type: SharedString
// container.initialObjects.unknownKey;  // ❌ Type error!
```

---

## Compatibility Modes

```typescript
// Mode "1": Interop with 1.x clients (default)
await client.createContainer(schema, "1");

// Mode "2": 2.x clients only, enables SharedTree
await client.createContainer(schema, "2");

// Mode affects runtime behavior:
// - "1": BasicRuntime
// - "2": BasicRuntime + RuntimeIdCompressor (for SharedTree)
```

---

## Common Patterns

### Auto-Save Indicator
```typescript
function setupAutoSaveIndicator(container: IFluidContainer) {
  container.on("dirty", () => {
    updateUI("Saving...");
  });
  
  container.on("saved", () => {
    updateUI("Saved");
  });
}
```

### Safe Cleanup
```typescript
async function closeContainer(container: IFluidContainer) {
  if (container.isDirty) {
    console.warn("Container has unsaved changes!");
    // Wait for save or save timeout
    await new Promise((resolve) => {
      const timer = setTimeout(resolve, 5000);
      container.once("saved", () => {
        clearTimeout(timer);
        resolve(undefined);
      });
    });
  }
  container.dispose();
}
```

### Create Dynamic Object
```typescript
async function createSharedMap(
  container: IFluidContainer
): Promise<ISharedMap> {
  const map = await container.create(SharedMap);
  
  // Store handle for persistence
  const root = container.initialObjects.root;  // Your root store
  root.set("myDynamicMap", map.handle);
  
  return map;
}
```

---

## Error Handling

```typescript
try {
  const { container } = await client.getContainer(id, schema, "2");
} catch (error) {
  console.error("Failed to load container:", error);
}

try {
  await container.attach();
} catch (error) {
  console.error("Failed to attach:", error);
}

try {
  const obj = await container.create(SharedMap);
} catch (error) {
  console.error("Failed to create object:", error);
}

// Disposed container errors
container.dispose();
try {
  container.connect();  // ❌ Throws
} catch (error) {
  console.error("Container is disposed");
}
```

---

## Version Management (Azure Only)

```typescript
// Get version history
const versions = await client.getContainerVersions(containerId, {
  maxCount: 5,  // Get last 5 versions
});

for (const version of versions) {
  console.log(`Version ${version.id} from ${version.date}`);
}

// Load specific version (read-only)
const { container: versionedContainer } = await client.viewContainerVersion(
  containerId,
  schema,
  versions[0],  // Load first version
  "2"
);

// Can read but not modify
const data = versionedContainer.initialObjects.myMap.get("key");
// versionedContainer.initialObjects.myMap.set(...);  // ❌ Fails (read-only)
```

---

## Member Info Access

```typescript
// Service-specific member info

// Azure Member
const azureMembers = audience.getMembers();
for (const [id, member] of azureMembers) {
  console.log(member.name);  // User's display name
  console.log(member.additionalDetails);  // Custom metadata
  for (const conn of member.connections) {
    console.log(`${conn.id}: ${conn.mode}`);  // Connection details
  }
}

// Tinylicious Member
const t9sMembers = audience.getMembers();
for (const [id, member] of t9sMembers) {
  console.log(member.name);  // User name
  console.log(member.connections);  // Connection list
}
```

---

## Debugging

```typescript
// Check internal container (if using fluid-static)
import { isInternalFluidContainer } from "@fluidframework/fluid-static";

if (isInternalFluidContainer(container)) {
  const internalContainer = container as IFluidContainerInternal;
  const iContainer = internalContainer.container;
  console.log("Internal container available for debugging");
}

// Logger setup (AzureClient only)
const client = new AzureClient({
  connection: { ... },
  logger: myCustomLogger,
});
```

---

## File Organization

```
src/
  components/
    ContainerComponent.tsx
      ├─ createClient()
      ├─ createContainer() 
      └─ loadContainer()
  
  services/
    fluidClient.ts        // Client singleton
    tokenProvider.ts      // ITokenProvider implementation
  
  types/
    containerSchema.ts    // Typed schema definitions
    audience.ts           // Audience helpers
  
  utils/
    containerHelpers.ts   // Auto-save, cleanup, etc.
```

---

## Key Takeaways

1. **Schema is King**: Define once, use consistently. Type-safe access via generics.
2. **Audience Aggregation**: Users have multiple connections, indexed by userId.
3. **State Events**: Listen for connection/dirty/saved states, not polling.
4. **Immutable Schema**: Can't change ContainerSchema or CompatibilityMode after creation.
5. **Service Separation**: Client creates container, Services provide audience.
6. **Token Responsibility**: Your code must implement ITokenProvider for auth.
7. **Clean Shutdown**: Check isDirty before dispose, handle disposed state.
8. **Generic Type Safety**: Use generic type parameters to get TypeScript help.

---

## Documentation Links

- **Full Analysis**: FluidFramework_API_Analysis.md (20 sections, 1000+ lines)
- **API Gaps Checklist**: API_GAPS_ANALYSIS_TEMPLATE.md (compliance checklist)
- **This Reference**: QUICK_REFERENCE.md (you are here)
