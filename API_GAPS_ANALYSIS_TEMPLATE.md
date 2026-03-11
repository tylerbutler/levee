# FluidFramework API Gap Analysis Template for LeveeClient

Use this template to compare LeveeClient against the FluidFramework standards.

## Quick Checklist: Core Client Methods

### Must Have (Critical)
- [ ] `createContainer(schema, compatibilityMode): Promise<{container, services}>`
- [ ] `getContainer(id, schema, compatibilityMode): Promise<{container, services}>`
- [ ] Accepts `ContainerSchema` with typed `initialObjects`
- [ ] Accepts `CompatibilityMode` ("1" or "2")

### Should Have (Important)
- [ ] Version management (viewContainerVersion, getContainerVersions)
- [ ] Optional token provider override
- [ ] Logger support (ITelemetryBaseLogger)
- [ ] ConfigProvider for feature gates
- [ ] Summary compression options

### Connection Configuration
- [ ] Support for connection config objects
- [ ] ITokenProvider interface compatibility
- [ ] Token refresh on auth failure
- [ ] documentPostCreateCallback support

---

## Core Interface Compliance

### IFluidContainer Must Support

#### Properties (Read-Only)
- [ ] `connectionState: ConnectionState` (Connected/Disconnected/etc)
- [ ] `isDirty: boolean` (unacknowledged changes)
- [ ] `disposed: boolean` (permanent disable flag)
- [ ] `initialObjects: InitialObjects<TContainerSchema>` (typed)
- [ ] `attachState: AttachState` (Detached/Attaching/Attached)

#### Methods
- [ ] `async attach(props?: ContainerAttachProps): Promise<string>` - Returns container ID
- [ ] `connect(): void` - From Disconnected state
- [ ] `disconnect(): void` - From Connected state
- [ ] `async create<T extends IFluidLoadable>(objectClass: SharedObjectKind<T>): Promise<T>`
- [ ] `dispose(): void`

#### Events (TypedEventEmitter)
- [ ] `"connected"` - No parameters
- [ ] `"disconnected"` - No parameters
- [ ] `"saved"` - All changes acknowledged
- [ ] `"dirty"` - First change after saved
- [ ] `"disposed"` - (error?: ICriticalContainerError)

---

## ServiceAudience Compliance

### IServiceAudience<M extends IMember> Must Support

#### Methods
- [ ] `getMembers(): ReadonlyMap<string, M>`
  - Keyed by userId (not clientId)
  - Aggregates multiple connections per user
  - Filters to interactive members only
  
- [ ] `getMyself(): Myself<M> | undefined`
  - Returns current user + currentConnection
  - Undefined if not connected

#### Events (TypedEventEmitter)
- [ ] `"membersChanged"` - No parameters
- [ ] `"memberAdded"(clientId: string, member: M)`
- [ ] `"memberRemoved"(clientId: string, member: M)`

### IMember Type Requirements
- [ ] `id: string` (userId)
- [ ] `connections: IConnection[]` (aggregated connections)

### IConnection Type Requirements
- [ ] `id: string` (clientId)
- [ ] `mode: "write" | "read"`

---

## Type System Compliance

### ContainerSchema
```typescript
// Must support:
{
  initialObjects: Record<string, SharedObjectKind>,  // Required
  dynamicObjectTypes?: readonly SharedObjectKind[]   // Optional
}
```

- [ ] Type-safe access: `container.initialObjects["key"]` returns correct type
- [ ] Generic type parameter inference: `<TContainerSchema extends ContainerSchema>`

### CompatibilityMode
```typescript
type CompatibilityMode = "1" | "2";
// "1": Interop with 1.x clients
// "2": 2.x clients only (enables SharedTree support)
```

- [ ] Runtime configuration differs by mode
- [ ] Set at container creation, immutable

---

## Connection Configuration Requirements

### For Local/Test Scenarios (like Tinylicious)
```typescript
{
  port?: number,
  domain?: string,
  tokenProvider?: ITokenProvider,  // Optional with defaults
}
```

### For Remote Services (like Azure)
```typescript
{
  type: "remote" | "local",
  endpoint: string,
  tokenProvider: ITokenProvider,   // Required
  tenantId?: string,               // Required for "remote"
}
```

### ITokenProvider Contract
- [ ] `fetchOrdererToken(tenantId, documentId?, refresh?): Promise<ITokenResponse>`
- [ ] `fetchStorageToken(tenantId, documentId, refresh?): Promise<ITokenResponse>`
- [ ] `documentPostCreateCallback?(documentId, creationToken): Promise<void>` (optional)

---

## Container Services Object

### Must Return From createContainer/getContainer
```typescript
{
  container: IFluidContainer<TContainerSchema>,
  services: {
    audience: IServiceAudience<ServiceSpecificMember>,
    // ... other service-specific fields
  }
}
```

### Service-Specific Member Example (Azure)
```typescript
interface AzureMember<T = any> extends IMember {
  name: string;                    // Service provides user names
  additionalDetails?: T;           // Custom metadata
}
```

---

## Feature Gate / Config Provider Support

### Minimum Required
```typescript
{
  "Fluid.Container.ForceWriteConnection": true
}
```

- [ ] Can override default feature gates via `IConfigProviderBase`
- [ ] Graceful degradation if not provided

---

## Error Handling Compliance

### Container Methods Must Handle
- [ ] `attach()` - Throws if not Detached state
- [ ] `attach()` - Throws if attachment fails
- [ ] `connect()` - Throws if connection fails
- [ ] `create()` - Throws if object creation fails
- [ ] Operations reject with meaningful error messages

### Disposed Container Behavior
- [ ] All methods fail gracefully after `dispose()`
- [ ] Attempting attach/connect/create raises errors
- [ ] "disposed" event emitted with optional error details

---

## Constructor & Initialization

### AzureClient Style (Required Props)
```typescript
new AzureClient({
  connection: AzureRemoteConnectionConfig | AzureLocalConnectionConfig,  // Required
  logger?: ITelemetryBaseLogger,
  configProvider?: IConfigProviderBase,
  summaryCompression?: boolean | ICompressionStorageConfig,
})
```

### TinyliciousClient Style (Optional Props)
```typescript
new TinyliciousClient({
  connection?: TinyliciousConnectionConfig,  // Optional, has defaults
  logger?: ITelemetryBaseLogger,
})
```

- [ ] Props object required or optional?
- [ ] All configurations properly typed
- [ ] Defaults documented and sensible

---

## Version Management (Optional but Nice-to-Have)

```typescript
// If implementing version support:
- [ ] async viewContainerVersion<T extends ContainerSchema>(
        id: string,
        schema: T,
        version: { id: string; date?: string },
        compatibilityMode: CompatibilityMode
      ): Promise<{ container: IFluidContainer<T> }>

- [ ] async getContainerVersions(
        id: string,
        options?: { maxCount: number }
      ): Promise<{ id: string; date?: string }[]>
```

---

## Testing Considerations

### Mock IFluidContainer Must Support
- [ ] Event emission/listening
- [ ] State transitions (connection states)
- [ ] Dirty state tracking
- [ ] Attach state tracking
- [ ] initialObjects type safety

### Mock ServiceAudience Must Support
- [ ] Member addition/removal events
- [ ] getMembers aggregation by userId
- [ ] getMyself returning current user + connection

### Integration Testing
- [ ] Create container → attach → verify ID returned
- [ ] Load container → verify initialObjects accessible
- [ ] Multiple connections → audience aggregates by userId
- [ ] Attach while dirty → state tracked correctly
- [ ] Version loading → read-only access enforced

---

## Exports Checklist

### From Main Package
- [ ] Client class (AzureClient/TinyliciousClient)
- [ ] Props/Config interfaces
- [ ] Container services type
- [ ] Member/audience types
- [ ] Version types (if supported)
- [ ] Re-export CompatibilityMode
- [ ] Re-export ITokenProvider
- [ ] Re-export ITelemetryBaseLogger
- [ ] Re-export IUser

### NOT Exported (Internal)
- [ ] IFluidContainer implementation (only interface)
- [ ] createFluidContainer function
- [ ] Internal runtime factories
- [ ] Service audience implementation

---

## Documentation Requirements

Each public API should document:
- [ ] Purpose and use case
- [ ] Type parameters (if generic)
- [ ] All parameters with types
- [ ] Return type with structure
- [ ] Possible exceptions/errors
- [ ] Important remarks or restrictions
- [ ] Examples where complex

---

## Performance Considerations

- [ ] Connection pooling supported?
- [ ] Token caching strategy documented
- [ ] Audience member aggregation efficient?
- [ ] Large initialObjects handled well?
- [ ] Memory leaks in event listeners prevented?

