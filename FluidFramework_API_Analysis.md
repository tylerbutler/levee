# FluidFramework Client Public API Comprehensive Analysis

## Executive Summary
This document provides a complete analysis of the AzureClient and TinyliciousClient public APIs from Microsoft's Fluid Framework, including their base classes, types, and dependencies. This is useful for comparing against competing implementations like LeveeClient.

---

## 1. AzureClient

**File**: `/packages/service-clients/azure-client/src/AzureClient.ts`

### Class Declaration
```typescript
export class AzureClient
```

### Constructor
```typescript
public constructor(properties: AzureClientProps)
```

**Parameters**:
- `properties: AzureClientProps` - Configuration object with:
  - `connection: AzureRemoteConnectionConfig | AzureLocalConnectionConfig` (required)
  - `logger?: ITelemetryBaseLogger` (optional)
  - `configProvider?: IConfigProviderBase` (optional)
  - `summaryCompression?: boolean | ICompressionStorageConfig` (optional)

### Public Methods

#### 1. createContainer
```typescript
public async createContainer<const TContainerSchema extends ContainerSchema>(
  containerSchema: TContainerSchema,
  compatibilityMode: CompatibilityMode,
): Promise<{
  container: IFluidContainer<TContainerSchema>;
  services: AzureContainerServices;
}>
```

**Purpose**: Creates a new detached container instance in Azure Fluid Relay
**Type Parameters**:
- `TContainerSchema extends ContainerSchema` - Used to infer type of 'initialObjects' in returned container

**Returns**: Promise with:
- `container: IFluidContainer<TContainerSchema>` - New detached container
- `services: AzureContainerServices` - Associated Azure-specific services

#### 2. getContainer
```typescript
public async getContainer<TContainerSchema extends ContainerSchema>(
  id: string,
  containerSchema: TContainerSchema,
  compatibilityMode: CompatibilityMode,
): Promise<{
  container: IFluidContainer<TContainerSchema>;
  services: AzureContainerServices;
}>
```

**Purpose**: Accesses an existing container by its unique ID
**Parameters**:
- `id: string` - Unique container ID in Azure Fluid Relay
- `containerSchema: TContainerSchema` - Schema for accessing data objects
- `compatibilityMode: CompatibilityMode` - Runtime compatibility mode ("1" or "2")

#### 3. viewContainerVersion
```typescript
public async viewContainerVersion<TContainerSchema extends ContainerSchema>(
  id: string,
  containerSchema: TContainerSchema,
  version: AzureContainerVersion,
  compatibilityMode: CompatibilityMode,
): Promise<{
  container: IFluidContainer<TContainerSchema>;
}>
```

**Purpose**: Loads a specific version of a container for viewing only (read-only access)
**Parameters**:
- `id: string` - Container ID
- `containerSchema: TContainerSchema` - Schema for data access
- `version: AzureContainerVersion` - Version to load
- `compatibilityMode: CompatibilityMode` - Runtime mode

**Returns**: Promise with:
- `container: IFluidContainer<TContainerSchema>` - Loaded container at specified version

#### 4. getContainerVersions
```typescript
public async getContainerVersions(
  id: string,
  options?: AzureGetVersionsOptions,
): Promise<AzureContainerVersion[]>
```

**Purpose**: Retrieves list of available versions for a container
**Parameters**:
- `id: string` - Container ID
- `options?: AzureGetVersionsOptions` - Options including `maxCount?: number` (default: 5, max shown is 5)

**Returns**: Promise<AzureContainerVersion[]> - Array of version metadata

---

## 2. TinyliciousClient

**File**: `/packages/service-clients/tinylicious-client/src/TinyliciousClient.ts`

### Class Declaration
```typescript
@sealed
export class TinyliciousClient
```

### Constructor
```typescript
public constructor(properties?: TinyliciousClientProps)
```

**Parameters**:
- `properties?: TinyliciousClientProps` (optional) with:
  - `connection?: TinyliciousConnectionConfig` (optional)
  - `logger?: ITelemetryBaseLogger` (optional)

### Public Methods

#### 1. createContainer
```typescript
public async createContainer<TContainerSchema extends ContainerSchema>(
  containerSchema: TContainerSchema,
  compatibilityMode: CompatibilityMode,
): Promise<{
  container: IFluidContainer<TContainerSchema>;
  services: TinyliciousContainerServices;
}>
```

#### 2. getContainer
```typescript
public async getContainer<TContainerSchema extends ContainerSchema>(
  id: string,
  containerSchema: TContainerSchema,
  compatibilityMode: CompatibilityMode,
): Promise<{
  container: IFluidContainer<TContainerSchema>;
  services: TinyliciousContainerServices;
}>
```

---

## 3. IFluidContainer Interface

**File**: `/packages/framework/fluid-static/src/fluidContainer.ts`

### Properties

```typescript
readonly connectionState: ConnectionState;
// Connection state (Connected, Disconnected, Connecting)

readonly isDirty: boolean;
// True if container has unacknowledged local changes

readonly disposed: boolean;
// True if container is permanently disabled

readonly initialObjects: InitialObjects<TContainerSchema>;
// Data objects/DDSes specified by schema

readonly attachState: AttachState;
// Detached, Attaching, or Attached state
```

### Events (via IEventProvider<IFluidContainerEvents>)

```typescript
on("connected", () => void)
// Container connected to Fluid service

on("disconnected", () => void)
// Container disconnected from service

on("saved", () => void)
// All local changes acknowledged by service

on("dirty", () => void)
// First local change after saved event

on("disposed", (error?: ICriticalContainerError) => void)
// Container closed/disposed
```

### Methods

```typescript
async attach(props?: ContainerAttachProps): Promise<string>
// Attach detached container, returns container ID

connect(): void
// Connect to delta stream (from Disconnected state)

disconnect(): void
// Disconnect from delta stream (from Connected state)

async create<T extends IFluidLoadable>(objectClass: SharedObjectKind<T>): Promise<T>
// Dynamically create new data object/DDS

dispose(): void
// Permanently disable container
```

---

## 4. Connection Configuration Types

### AzureConnectionConfig (Base)
```typescript
interface AzureConnectionConfig {
  type: AzureConnectionConfigType;              // "local" | "remote"
  endpoint: string;                             // URI to service endpoint
  tokenProvider: ITokenProvider;                // Token provider instance
}
```

### AzureRemoteConnectionConfig
```typescript
interface AzureRemoteConnectionConfig extends AzureConnectionConfig {
  type: "remote";
  tenantId: string;                             // Unique tenant identifier
}
```

### AzureLocalConnectionConfig
```typescript
interface AzureLocalConnectionConfig extends AzureConnectionConfig {
  type: "local";
}
```

### TinyliciousConnectionConfig
```typescript
interface TinyliciousConnectionConfig {
  port?: number;                               // Default: defaultTinyliciousPort
  domain?: string;                             // Default: defaultTinyliciousEndpoint
  tokenProvider?: ITokenProvider;              // Default: InsecureTinyliciousTokenProvider
}
```

---

## 5. ITokenProvider Interface

**File**: `/packages/drivers/routerlicious-driver/src/tokens.ts`

```typescript
interface ITokenProvider {
  // Fetch orderer token
  fetchOrdererToken(
    tenantId: string,
    documentId?: string,
    refresh?: boolean,
  ): Promise<ITokenResponse>;

  // Fetch storage token
  fetchStorageToken(
    tenantId: string,
    documentId: string,
    refresh?: boolean,
  ): Promise<ITokenResponse>;

  // Optional callback after document creation
  documentPostCreateCallback?(
    documentId: string,
    creationToken: string,
  ): Promise<void>;
}

interface ITokenResponse {
  jwt: string;                    // JWT token value
  fromCache?: boolean;            // Whether from local cache (undefined = unknown)
}
```

---

## 6. InsecureTokenProvider Class

**File**: `/packages/runtime/test-runtime-utils/src/insecureTokenProvider.ts`

### Implementation
```typescript
@sealed
@internal
export class InsecureTokenProvider implements ITokenProvider {
  constructor(
    private readonly tenantKey: string,           // Private server key for token generation
    private readonly user: IInsecureUser,         // Associated user
    private readonly scopes?: ScopeType[],        // Default: [DocRead, DocWrite, SummaryWrite]
    private readonly attachContainerScopes?: ScopeType[],  // For attach operations
  )

  readonly fetchOrdererToken = this.fetchToken.bind(this);
  readonly fetchStorageToken = this.fetchToken.bind(this);

  private async fetchToken(
    tenantId: string,
    documentId?: string,
  ): Promise<ITokenResponse>
}
```

**Note**: For development/testing only. Not production-ready.

---

## 7. ServiceAudience & Member Types

### IServiceAudience<M extends IMember> Interface

**File**: `/packages/framework/fluid-static/src/types.ts`

```typescript
interface IServiceAudience<M extends IMember>
  extends IEventProvider<IServiceAudienceEvents<M>> {
  
  getMembers(): ReadonlyMap<string, M>;
  // Map of userId -> member object

  getMyself(): Myself<M> | undefined;
  // Current user info (or undefined if not connected)
}
```

### Events
```typescript
on("membersChanged", () => void)
// Members added/removed

on("memberAdded", (clientId: string, member: M) => void)
// Member joined session

on("memberRemoved", (clientId: string, member: M) => void)
// Member left session
```

### IMember Interface
```typescript
interface IMember {
  readonly id: string;                         // User ID
  readonly connections: IConnection[];         // Multiple connections per user
}

interface IConnection {
  readonly id: string;                         // Connection ID
  readonly mode: "write" | "read";            // Connection mode
}
```

### Azure-specific Types

```typescript
interface AzureUser<T = any> extends IUser {
  name: string;                                // Required user name
  additionalDetails?: T;                       // Custom app-specific data
}

interface AzureMember<T = any> extends IMember {
  name: string;
  additionalDetails?: T;
}

type IAzureAudience = IServiceAudience<AzureMember>;
```

### Tinylicious-specific Types

```typescript
interface TinyliciousUser extends IUser {
  readonly name: string;
}

interface TinyliciousMember extends IMember {
  readonly name: string;
}

type ITinyliciousAudience = IServiceAudience<TinyliciousMember>;
```

---

## 8. ContainerSchema Type

**File**: `/packages/framework/fluid-static/src/types.ts`

```typescript
interface ContainerSchema {
  // Data objects/DDSes created on first container creation
  readonly initialObjects: Record<string, SharedObjectKind>;

  // Types that can be dynamically created
  readonly dynamicObjectTypes?: readonly SharedObjectKind[];
}
```

**Example**:
```typescript
const schema: ContainerSchema = {
  initialObjects: {
    map1: SharedMap,
    pair1: KeyValueDataObject,
  },
  dynamicObjectTypes: [SharedMap, SharedString],
};
```

---

## 9. CompatibilityMode Type

**File**: `/packages/framework/fluid-static/src/types.ts`

```typescript
type CompatibilityMode = "1" | "2";

// "1": Support full interop between 2.x clients and 1.x clients
// "2": Support interop between 2.x clients only
```

### Runtime Configuration Per Mode

```typescript
// Mode "1": {}  (no special options)

// Mode "2": {
//   enableRuntimeIdCompressor: "on"  (required for SharedTree support)
// }
```

---

## 10. Container Services Objects

### AzureContainerServices
```typescript
interface AzureContainerServices {
  audience: IAzureAudience;  // Azure-specific audience with member names
}
```

### TinyliciousContainerServices
```typescript
interface TinyliciousContainerServices {
  audience: ITinyliciousAudience;  // Tinylicious-specific audience
}
```

---

## 11. Container Version Types

### AzureContainerVersion
```typescript
interface AzureContainerVersion {
  id: string;                    // Version ID
  date?: string;                 // ISO 8601 timestamp (YYYY-MM-DDTHH:MM:SSZ)
}
```

### AzureGetVersionsOptions
```typescript
interface AzureGetVersionsOptions {
  maxCount: number;              // Maximum number of versions to retrieve
}
```

---

## 12. Supporting Types & Enums

### AttachState (from container-definitions)
```
Detached    - Container not yet attached
Attaching   - Attachment in progress
Attached    - Container is attached
```

### ConnectionState (from container-definitions)
```
Connecting  - Connection attempt in progress
Connected   - Connected to service
Disconnected - Not connected to service
CatchingUp   - Connecting and syncing state
```

### CompatibilityMode Runtime Options
```typescript
{
  "1": {},
  "2": {
    enableRuntimeIdCompressor: "on"  // For SharedTree support
  }
}
```

---

## 13. Feature Flags / Config Provider

### Default Feature Gates
Both clients set default feature gates:

**Azure Client**:
```typescript
{
  "Fluid.Container.ForceWriteConnection": true
}
```

**Tinylicious Client**:
```typescript
{
  "Fluid.Container.ForceWriteConnection": true
}
```

These can be overridden via `IConfigProviderBase` passed to clients.

---

## 14. Internal Helper Functions (Not Public API)

### createFluidContainer (internal)
```typescript
async function createFluidContainer<TContainerSchema extends ContainerSchema>(
  props: { container: IContainer }
): Promise<IFluidContainer<TContainerSchema>>
```

### createDOProviderContainerRuntimeFactory (internal)
```typescript
function createDOProviderContainerRuntimeFactory(props: {
  schema: ContainerSchema;
  compatibilityMode: CompatibilityMode;
}): IRuntimeFactory
```

### createServiceAudience (internal)
```typescript
function createServiceAudience<TMember extends IMember>(props: {
  container: IContainer;
  createServiceMember: (audienceMember: IClient) => TMember;
}): IServiceAudience<TMember>
```

---

## 15. Type Parameters Summary

### SharedObjectKind
Represents a class of `DataObject` or `SharedObject` that can be instantiated.

Examples from Fluid Framework:
- `SharedMap`
- `SharedString`
- `SharedArray`
- `SharedTree`
- Custom `DataObject` classes

### IFluidLoadable
Base interface for objects that can be stored and retrieved in containers.

---

## 16. Error Handling

### IFluidContainer Methods
- `attach()` - Throws if container not in Detached state or attach fails
- `connect()` - Throws if connection fails; should only call when Disconnected
- `disconnect()` - Should only call when Connected
- `create()` - Throws if object creation fails
- `dispose()` - No error handling; closes container

### ICriticalContainerError
Provided to "disposed" event if container closed due to error (vs. explicit disposal).

---

## 17. Comparison Summary: AzureClient vs TinyliciousClient

| Feature | AzureClient | TinyliciousClient |
|---------|-------------|-------------------|
| Constructor | Required props | Optional props |
| Connection Config | AzureConnectionConfig (required) | TinyliciousConnectionConfig (optional) |
| Version Management | ✓ getContainerVersions, viewContainerVersion | ✗ |
| Token Provider | Required via connection | Optional (defaults provided) |
| Audience Type | IAzureAudience (with names) | ITinyliciousAudience (with names) |
| Supported Services | Azure Fluid Relay or local instance | Tinylicious (local dev service) |
| Remote vs Local | Both supported | Local only |
| Feature Flags | Customizable via configProvider | Fixed defaults |
| Summary Compression | Supported | Not exposed |

---

## 18. Key API Invariants

1. **Container Lifecycle**: Detached → (Attaching) → Attached
2. **Connection States**: Disconnected ↔ Connected (with Connecting/CatchingUp transients)
3. **Dirty State**: Dirty when unacknowledged local changes exist
4. **Schema Immutability**: ContainerSchema defined at creation time
5. **Member Aggregation**: Multiple connections aggregated by userId in audience
6. **Compatibility Mode**: Set at container creation, affects runtime behavior
7. **Version Loading**: viewContainerVersion returns read-only container
8. **Token Refresh**: ITokenProvider receives `refresh` flag when token expires

---

## 19. Export Summary

### From @fluidframework/azure-client
- `AzureClient` (class)
- `AzureClientProps`, `AzureContainerServices`, `AzureContainerVersion`
- `AzureConnectionConfig`, `AzureRemoteConnectionConfig`, `AzureLocalConnectionConfig`
- `AzureMember`, `AzureUser`, `IAzureAudience`
- `AzureGetVersionsOptions`
- `ITokenProvider`, `ITokenResponse` (re-exported)
- `CompatibilityMode` (re-exported)
- `ITelemetryBaseLogger`, `IUser` (re-exported)

### From @fluidframework/tinylicious-client
- `TinyliciousClient` (class)
- `TinyliciousClientProps`, `TinyliciousConnectionConfig`, `TinyliciousContainerServices`
- `TinyliciousMember`, `TinyliciousUser`, `ITinyliciousAudience`
- `CompatibilityMode` (re-exported)

---

## 20. Known Limitations & Design Notes

1. **External IFluidContainer Implementations**: Not supported; sealed interface
2. **Attach Method Override**: Service-specific clients override `attach()` on base FluidContainer
3. **Member Filtering**: Only interactive (human) members included in audience by default
4. **Token Provider Responsibility**: Host application fully responsible for token generation and refresh
5. **Version API Limitations**: Max 5 versions shown by default; maxCount is required parameter
6. **Compatibility Mode**: Must be specified at container creation; cannot be changed
7. **Storage Compression**: Azure-specific feature; not available in Tinylicious

