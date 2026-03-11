# FluidFramework Client APIs - Executive Summary

## Overview
This document summarizes the key public APIs from Microsoft's FluidFramework AzureClient and TinyliciousClient for comparison with LeveeClient.

**Full Analysis**: See `FluidFramework_API_Analysis.md`  
**API Gaps Checklist**: See `API_GAPS_ANALYSIS_TEMPLATE.md`

---

## Core Client Classes

### 1. AzureClient
**Location**: `@fluidframework/azure-client`

```typescript
// Constructor
new AzureClient({
  connection: AzureRemoteConnectionConfig | AzureLocalConnectionConfig,  // Required
  logger?: ITelemetryBaseLogger,
  configProvider?: IConfigProviderBase,
  summaryCompression?: boolean | ICompressionStorageConfig,
})

// Methods
createContainer<T extends ContainerSchema>(schema: T, compatibilityMode: CompatibilityMode)
  → Promise<{ container: IFluidContainer<T>, services: AzureContainerServices }>

getContainer<T extends ContainerSchema>(id: string, schema: T, compatibilityMode: CompatibilityMode)
  → Promise<{ container: IFluidContainer<T>, services: AzureContainerServices }>

viewContainerVersion<T extends ContainerSchema>(
  id: string, schema: T, version: AzureContainerVersion, compatibilityMode: CompatibilityMode)
  → Promise<{ container: IFluidContainer<T> }>  // Read-only

getContainerVersions(id: string, options?: { maxCount: number })
  → Promise<AzureContainerVersion[]>
```

### 2. TinyliciousClient
**Location**: `@fluidframework/tinylicious-client`

```typescript
// Constructor (props optional)
new TinyliciousClient(properties?: {
  connection?: TinyliciousConnectionConfig,  // Optional
  logger?: ITelemetryBaseLogger,
})

// Methods (same as AzureClient, but no version support)
createContainer<T extends ContainerSchema>(schema: T, compatibilityMode: CompatibilityMode)
  → Promise<{ container: IFluidContainer<T>, services: TinyliciousContainerServices }>

getContainer<T extends ContainerSchema>(id: string, schema: T, compatibilityMode: CompatibilityMode)
  → Promise<{ container: IFluidContainer<T>, services: TinyliciousContainerServices }>
```

---

## IFluidContainer Interface (Core)

**All containers implement this interface.**

### Properties
```typescript
readonly connectionState: ConnectionState        // Connected | Disconnected | Connecting
readonly isDirty: boolean                       // Has unacknowledged local changes
readonly disposed: boolean                      // Permanently disabled
readonly initialObjects: InitialObjects<T>     // Typed initial data objects
readonly attachState: AttachState               // Detached | Attaching | Attached
```

### Methods
```typescript
attach(props?: ContainerAttachProps): Promise<string>    // Attach & return container ID
connect(): void                                         // Connect to delta service
disconnect(): void                                      // Disconnect from service
create<T>(objectClass: SharedObjectKind<T>): Promise<T> // Dynamically create object
dispose(): void                                         // Permanently close
```

### Events
```typescript
on("connected", () => void)                    // Connected to service
on("disconnected", () => void)                 // Disconnected from service
on("saved", () => void)                        // All changes acknowledged
on("dirty", () => void)                        // First change after saved
on("disposed", (error?: Error) => void)        // Container closed
```

---

## ServiceAudience Interface (Collaboration)

**All clients provide an audience object for tracking users.**

```typescript
interface IServiceAudience<M extends IMember> {
  // Get all current users (keyed by userId, not clientId)
  getMembers(): ReadonlyMap<string, M>
  
  // Get self (includes currentConnection ID)
  getMyself(): Myself<M> | undefined
  
  // Events
  on("membersChanged", () => void)
  on("memberAdded", (clientId: string, member: M) => void)
  on("memberRemoved", (clientId: string, member: M) => void)
}

interface IMember {
  id: string                    // User ID
  connections: IConnection[]    // Multiple connections per user
}

interface IConnection {
  id: string                    // Connection ID
  mode: "write" | "read"        // Read or write access
}
```

### Azure-Specific Extensions
```typescript
interface AzureMember extends IMember {
  name: string                  // User's display name (provided by Azure)
  additionalDetails?: any       // Custom metadata
}
```

### Tinylicious-Specific Extensions
```typescript
interface TinyliciousMember extends IMember {
  name: string                  // User's display name
}
```

---

## ContainerSchema Type

**Defines what data objects are available in a container.**

```typescript
interface ContainerSchema {
  // Data objects created on first container creation (required)
  initialObjects: Record<string, SharedObjectKind>
  
  // Types that can be dynamically created (optional)
  dynamicObjectTypes?: readonly SharedObjectKind[]
}

// Example
const schema: ContainerSchema = {
  initialObjects: {
    myMap: SharedMap,
    myString: SharedString,
  },
  dynamicObjectTypes: [SharedMap, SharedString, SharedTree],
}
```

---

## CompatibilityMode Type

```typescript
type CompatibilityMode = "1" | "2"

// "1": Interoperable with 1.x clients
// "2": Only 2.x clients (enables SharedTree support, enables runtime ID compressor)
```

Set at container creation time, affects runtime behavior.

---

## Connection Configuration

### Azure Remote
```typescript
{
  type: "remote"
  endpoint: string                   // Service discovery endpoint
  tenantId: string                   // Unique tenant identifier
  tokenProvider: ITokenProvider      // For authentication
}
```

### Azure Local
```typescript
{
  type: "local"
  endpoint: string                   // Local instance endpoint
  tokenProvider: ITokenProvider      // For authentication
  // No tenantId
}
```

### Tinylicious
```typescript
{
  port?: number                      // Default from driver
  domain?: string                    // Default from driver
  tokenProvider?: ITokenProvider     // Optional (has insecure default)
}
```

---

## ITokenProvider Interface

**Both clients require a token provider for authentication.**

```typescript
interface ITokenProvider {
  // Get orderer token (delta service)
  fetchOrdererToken(
    tenantId: string,
    documentId?: string,
    refresh?: boolean              // True if previous token expired
  ): Promise<ITokenResponse>
  
  // Get storage token (blob storage)
  fetchStorageToken(
    tenantId: string,
    documentId: string,
    refresh?: boolean              // True if previous token expired
  ): Promise<ITokenResponse>
  
  // Optional: Verify creation
  documentPostCreateCallback?(
    documentId: string,
    creationToken: string
  ): Promise<void>
}

interface ITokenResponse {
  jwt: string                        // JWT token
  fromCache?: boolean                // Was from local cache?
}
```

---

## Key Differences: AzureClient vs TinyliciousClient

| Feature | Azure | Tinylicious |
|---------|-------|-------------|
| **Constructor** | Required props | Optional props |
| **Connection** | Required config | Optional config |
| **Version APIs** | ✓ Yes | ✗ No |
| **Token Provider** | Required | Optional (default provided) |
| **Use Case** | Production (remote) or testing (local) | Local development only |
| **Audience Names** | ✓ Yes (from Azure) | ✓ Yes |
| **Feature Flags** | Customizable | Fixed defaults |

---

## Container Lifecycle

### Create New Container
```typescript
const { container, services } = await client.createContainer(schema, "2")
// container.attachState === "Detached"
// container.connectionState === "Connecting" or "Connected"

const containerId = await container.attach()
// container.attachState === "Attached"
// Persisted to service
```

### Load Existing Container
```typescript
const { container, services } = await client.getContainer(id, schema, "2")
// container.attachState === "Attached"
// Ready to use immediately
```

### View Version (Azure Only)
```typescript
const { container } = await client.viewContainerVersion(id, schema, version, "2")
// container is read-only
// Cannot attach, create, or modify
```

---

## State Machine

### Attachment States
```
Detached → Attaching → Attached
                        ↑
                    (stays)
```

### Connection States
```
Disconnected ⟷ Connecting ⟷ Connected
                            (normal)
            ↓ ↓ ↑ ↑
      CatchingUp (recovering)
```

### Dirty State
```
[Not dirty] → [dirty] → [saved]
   ↑             ↓
   └─────────────┘
```

---

## Error Handling

**Key Methods Must Throw**:
- `attach()` - If already attached or attach fails
- `connect()` - If not disconnected or connection fails
- `create()` - If object creation fails
- Any method on disposed container

**Dispose Event**:
- Emitted with `error` param if closed due to error
- Emitted with no param if explicit `dispose()` called

---

## Feature Flags / Config

Both clients set default feature gate:
```typescript
"Fluid.Container.ForceWriteConnection": true
```

Can be overridden via `IConfigProviderBase` in AzureClient constructor.

---

## Audience Member Aggregation

**Important**: Members are aggregated by userId, not clientId.

A single user with 2 browser tabs:
- `getMembers()` returns 1 entry with `id = userId`
- That entry has `connections = [{ id: clientId1, mode: "write" }, { id: clientId2, mode: "write" }]`
- Only interactive connections included (non-interactive like summarizers excluded)

---

## Public Exports

### @fluidframework/azure-client
- `AzureClient`
- `AzureClientProps`, `AzureRemoteConnectionConfig`, `AzureLocalConnectionConfig`
- `AzureContainerServices`, `AzureContainerVersion`, `AzureGetVersionsOptions`
- `AzureMember`, `AzureUser`, `IAzureAudience`
- `CompatibilityMode` (re-export from fluid-static)
- `ITokenProvider`, `ITokenResponse` (re-export from routerlicious-driver)
- `ITelemetryBaseLogger`, `IUser` (re-export)

### @fluidframework/tinylicious-client
- `TinyliciousClient`
- `TinyliciousClientProps`, `TinyliciousConnectionConfig`
- `TinyliciousContainerServices`, `TinyliciousMember`, `TinyliciousUser`, `ITinyliciousAudience`
- `CompatibilityMode` (re-export)

### @fluidframework/fluid-static
- `IFluidContainer` (interface only)
- `ContainerSchema`
- `IServiceAudience`, `IMember`, `IConnection`
- `Myself` (member with currentConnection)
- Helper functions (createFluidContainer, etc.) - mostly internal

---

## Design Patterns & Invariants

1. **Generic Type Safety**: All container methods are generic on `ContainerSchema`, preserving type safety for `initialObjects`
2. **Member Aggregation**: Audience always aggregates connections by userId
3. **Service Separation**: Container logic vs. service logic separated (IFluidContainer + Container Services)
4. **Event-Driven**: All state changes exposed via events
5. **Immutable at Creation**: Schema and CompatibilityMode set at creation, cannot change
6. **Read-Only Properties**: All container properties are read-only
7. **Connection Pooling**: Not exposed in public API; implementation detail

---

## Known Limitations

1. **No External IFluidContainer Implementations**: Interface is sealed
2. **Attach Override Per Service**: Base implementation throws; each service client provides implementation
3. **Version APIs Azure-Only**: Tinylicious doesn't support version viewing
4. **Max 5 Versions by Default**: Azure version API defaults to 5 max
5. **Token Refresh Required**: Host responsible for implementing retry with refresh flag
6. **No Built-in Caching**: Token caching up to ITokenProvider implementation

---

## For LeveeClient Comparison

**Critical to Match**:
- ✓ Client class with createContainer/getContainer methods
- ✓ IFluidContainer interface with all properties and events
- ✓ ServiceAudience with member aggregation
- ✓ ContainerSchema type support
- ✓ CompatibilityMode ("1" or "2")
- ✓ ITokenProvider interface

**Nice to Have**:
- ○ Version management (viewContainerVersion, getContainerVersions)
- ○ Logger support
- ○ Config provider for feature gates
- ○ Summary compression options

**See Full Details**:
- Full API spec: `FluidFramework_API_Analysis.md` (20 sections)
- Gap checklist: `API_GAPS_ANALYSIS_TEMPLATE.md` (detailed compliance checklist)

