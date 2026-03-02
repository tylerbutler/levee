---
marp: true
theme: default
paginate: true
title: Levee Architecture
author: Tyler Butler
---

# Levee Architecture

## A Fluid Framework Service in Elixir/Gleam

Real-time collaborative applications with a functional backend

---

# What is Levee?

**Levee** is a Fluid Framework-compatible service written in **Elixir** and **Gleam**

**Components:**

1. **Levee Server** - Elixir/Gleam backend service
2. **levee-driver** - TypeScript driver implementing Fluid interfaces
3. **levee-client** - High-level TypeScript API for applications

---

# Why Elixir/Gleam?

- **Concurrency** - BEAM VM handles millions of lightweight processes
- **Fault tolerance** - "Let it crash" supervision trees
- **Real-time** - Built for WebSocket and persistent connections
- **Gleam** - Type-safe functional language on BEAM

Perfect fit for collaborative document services

---

# Architecture Overview

```
┌─────────────────────────────────────┐
│  Your Application                   │
└──────────────┬──────────────────────┘
               │
┌──────────────▼──────────────────────┐
│  levee-client (High-level API)      │
└──────────────┬──────────────────────┘
               │
┌──────────────▼──────────────────────┐
│  levee-driver (Fluid Interfaces)    │
└──────────────┬──────────────────────┘
               │
     ┌─────────┴─────────┐
     │                   │
┌────▼────┐       ┌──────▼──────┐
│WebSocket│       │  REST API   │
└────┬────┘       └──────┬──────┘
     │                   │
┌────▼───────────────────▼────┐
│       Levee Server          │
│      (Elixir / Gleam)       │
└─────────────────────────────┘
```

---

# Part 1: Levee Server

---

# Server Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Levee Server                            │
├─────────────────────────────────────────────────────────────┤
│  Elixir Layer (Runtime & Web)                               │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────┐ │
│  │ Document Session │  │ WebSocket/REST  │  │   Storage   │ │
│  │   (GenServer)    │  │  (Wisp/Mist)    │  │    (ETS)    │ │
│  └────────┬─────────┘  └────────┬────────┘  └─────────────┘ │
├───────────┼─────────────────────┼───────────────────────────┤
│  Gleam Layer (Protocol Logic)   │                           │
│  ┌─────────────────────────────────────────────────────────┐│
│  │ Sequencing │ JWT │ Validation │ Nack │ Messages │ Types ││
│  └─────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────┘
                          BEAM VM
```

---

# Why Two Languages?

**Gleam for Protocol Logic:**
- Type-safe, immutable state machines
- Compile-time guarantees for complex protocol rules
- No runtime exceptions from type errors
- Self-documenting protocol types

**Elixir for Runtime:**
- OTP supervision trees for fault tolerance
- Wisp/Mist for HTTP, Beryl for WebSocket
- GenServer for per-document session state
- Ecosystem of production-ready libraries

Both compile to **BEAM bytecode** - zero-cost interop

---

# Gleam Components Overview

```
levee_protocol/src/
├── levee_protocol.gleam   # Public API facade
├── types.gleam            # Core Fluid types
├── sequencing.gleam       # Sequence number logic
├── jwt.gleam              # Token validation
├── validation.gleam       # Message validation
├── nack.gleam             # Error responses
├── message.gleam          # WebSocket messages
├── signal.gleam           # Ephemeral signals
└── summary.gleam          # Snapshot types
```

~2,200 lines of type-safe protocol logic

---

# Gleam: Sequence Number Management

The **heart of collaborative editing** - ensuring causal ordering

```gleam
// Four sequence number components
type SequenceState {
  SequenceState(
    sequence_number: Int,           // SN: Global op order
    clients: Dict(String, Int),     // CSN per client
    min_sequence_number: Int,       // MSN: Minimum RSN
  )
}

// Assign SN to incoming operation
fn assign_sequence_number(
  state: SequenceState,
  client_id: String,
  csn: Int,       // Client's sequence number
  rsn: Int,       // Reference sequence number
) -> Result(#(SequenceState, Int), SequenceError)
```

---

# Sequence Numbers Explained

| Abbrev | Name | Purpose |
|--------|------|---------|
| **SN** | Sequence Number | Server-assigned global order |
| **CSN** | Client Sequence Number | Per-client monotonic counter |
| **RSN** | Reference Sequence Number | Client's last-seen SN when submitting |
| **MSN** | Minimum Sequence Number | Minimum RSN across all clients |

**Validation rules (enforced in Gleam):**
- CSN must be monotonically increasing per client
- RSN cannot be from the future
- Client must be known to session

---

# Gleam: JWT Validation

Type-safe token validation with exhaustive error handling:

```gleam
type JwtError {
  TokenExpired
  TenantMismatch(expected: String, got: String)
  DocumentMismatch(expected: String, got: String)
  MissingScope(required: String)
  InvalidClaim(field: String)
}

fn validate_token(
  claims: TokenClaims,
  tenant_id: String,
  document_id: String,
  required_scope: String,
) -> Result(Nil, JwtError)
```

Compiler ensures all error cases are handled

---

# Gleam: Message Types

Protocol messages defined as algebraic data types:

```gleam
type MessageType {
  NoOp
  ClientJoin
  ClientLeave
  Propose
  Reject
  Accept
  Summarize
  SummaryAck
  SummaryNack
  Operation
  RoundTrip
}

type ConnectionMode {
  WriteMode
  ReadMode
}
```

Pattern matching ensures exhaustive handling

---

# Gleam: Nack (Negative Acknowledgment)

Type-safe error responses when ops are rejected:

```gleam
type NackErrorType {
  ThrottlingError    // 429 - Rate limited
  InvalidScopeError  // 403 - Permission denied
  BadRequestError    // 400 - Malformed
  LimitExceededError // 429 - Too large
}

fn bad_request(message: String) -> Nack
fn invalid_scope(required: String) -> Nack
fn throttled(retry_after: Int) -> Nack
fn read_only_client() -> Nack
```

---

# Gleam: Validation Functions

Composable validation with clear error types:

```gleam
fn validate_message_size(
  message: DocumentMessage,
  max_size: Int,
) -> Result(Nil, ValidationError)

fn validate_write_mode(
  mode: ConnectionMode,
) -> Result(Nil, ValidationError)

fn validate_scope(
  claims: TokenClaims,
  required: String,
) -> Result(Nil, ValidationError)
```

---

# Why Gleam for Protocol Logic?

**1. Correctness by construction**
- Invalid states are unrepresentable
- Compiler catches protocol violations

**2. Exhaustive pattern matching**
- Handle every message type
- No forgotten error cases

**3. Immutable state machines**
- Sequence state can't be corrupted
- Easy to reason about transitions

**4. Zero-cost BEAM interop**
- Call from Elixir like any Erlang module
- No serialization overhead

---

# Elixir Ecosystem Components

| Component | Library | Purpose |
|-----------|---------|---------|
| HTTP Server | **Mist** | Gleam HTTP server |
| Web Framework | **Wisp** | Routing, middleware, request handling |
| WebSocket | **Beryl** | Channel-based WebSocket handling |
| JWT | **gwt** | Token signing and verification (Gleam) |
| Storage | **ETS** | In-memory key-value (dev) |

All battle-tested, production-grade libraries

---

# Elixir: Application Structure

```
lib/levee/
├── application.ex       # OTP app, supervision tree
├── auth/
│   ├── jwt.ex          # JOSE JWT signing/verification
│   └── tenant_secrets.ex
├── documents/
│   ├── session.ex      # GenServer per document
│   ├── registry.ex     # Session lookup
│   └── supervisor.ex   # Dynamic supervisor
├── protocol/
│   └── bridge.ex       # Gleam interop wrapper
└── storage/
    ├── behaviour.ex    # Storage interface
    └── ets.ex          # In-memory backend
```

---

# Elixir: Document Session

One **GenServer process per document** - isolation and concurrency:

```elixir
defmodule Levee.Documents.Session do
  use GenServer

  defstruct [
    :document_id,
    :sequence_state,      # Gleam SequenceState
    :connected_clients,
    :operation_history,   # Last 1000 ops for catch-up
    :pending_summaries
  ]

  # Handle op submission
  def handle_call({:submit_op, client_id, op}, _from, state) do
    # Calls Gleam sequencing logic
    case Protocol.Bridge.assign_sequence_number(...) do
      {:ok, new_state, seq_num} -> ...
      {:error, reason} -> ...
    end
  end
end
```

---

# Elixir: Protocol Bridge

Wraps Gleam modules for ergonomic Elixir usage:

```elixir
defmodule Levee.Protocol.Bridge do
  # Gleam modules compile to atoms like :levee_protocol@sequencing
  @sequencing :levee_protocol@sequencing

  def assign_sequence_number(state, client_id, csn, rsn) do
    case @sequencing.assign_sequence_number(state, client_id, csn, rsn) do
      {:ok, {new_state, seq_num}} -> {:ok, new_state, seq_num}
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  def build_nack(type, message) do
    :levee_protocol@nack.bad_request(message)
  end
end
```

---

# Gleam: Web Layer (Wisp/Mist + Beryl)

```
server/levee_web/src/levee_web/
├── router.gleam               # Route definitions (Wisp)
├── context.gleam              # Typed request context
├── handlers/
│   ├── documents.gleam        # Document CRUD
│   ├── deltas.gleam           # Delta/ops retrieval
│   ├── git.gleam              # Git-like storage
│   └── admin_spa.gleam        # Admin UI
└── middleware/
    ├── jwt_auth.gleam         # JWT authentication
    ├── cors.gleam             # CORS handling
    └── session_auth.gleam     # Session auth

levee_channels/src/levee_channels/
├── document_channel.gleam     # Beryl channel for real-time
└── runtime.gleam              # Channel runtime
```

**Beryl channels** handle WebSocket connections with:
- Phoenix-compatible wire protocol (works with phoenix.js client)
- Per-channel process isolation on BEAM
- Built-in heartbeat handling

---

# Server API

| Protocol | Endpoint | Purpose |
|----------|----------|---------|
| REST | `/documents/{tenantId}` | Create/get documents |
| REST | `/repos/{tenantId}/git/*` | Blob/tree/commit storage |
| REST | `/deltas/{tenantId}/{docId}` | Historical operations |
| WebSocket | `/socket` | Real-time connection |

---

# Real-time Protocol

**Channel:** `document:{tenantId}:{documentId}`

| Event | Direction | Purpose |
|-------|-----------|---------|
| `connect_document` | Client → Server | Initialize session |
| `connect_document_success` | Server → Client | Client ID, initial state |
| `submitOp` | Client → Server | Send operation |
| `op` | Server → All | Broadcast sequenced op |
| `submitSignal` | Client → Server | Send ephemeral signal |
| `signal` | Server → Clients | Broadcast signal |
| `nack` | Server → Client | Reject operation |

---

# Request Flow: Submit Operation

```
Client                     Elixir                      Gleam
  │                          │                           │
  │ submitOp(op, csn, rsn)   │                           │
  │─────────────────────────>│                           │
  │                          │                           │
  │                   DocumentChannel                    │
  │                          │ validate token            │
  │                          │──────────────────────────>│
  │                          │<──────────────────────────│
  │                          │                           │
  │                     Session (GenServer)              │
  │                          │ assign_sequence_number    │
  │                          │──────────────────────────>│
  │                          │<──── {:ok, state, sn} ────│
  │                          │                           │
  │        op(sequenced)     │                           │
  │<─────────────────────────│                           │
```

---

# Server Configuration

```elixir
# Service configuration sent to clients
%{
  max_message_size: 16_384,        # 16 KB
  block_size: 65_536,              # 64 KB
  summary: %{
    idle_time: 5000,
    max_ops: 1000,
    max_ack_wait_time: 600_000
  }
}

# Session maintains last 1000 ops for delta catch-up
@max_history_size 1000
```

---

# Storage Abstraction

Pluggable storage backend via Elixir behaviour:

```elixir
defmodule Levee.Storage.Behaviour do
  @callback create_document(tenant_id, doc_id) :: {:ok, doc} | {:error, term}
  @callback get_document(tenant_id, doc_id) :: {:ok, doc} | {:error, :not_found}

  # Delta operations
  @callback store_ops(tenant_id, doc_id, ops) :: :ok
  @callback get_ops(tenant_id, doc_id, from, to) :: {:ok, ops}

  # Git-like storage
  @callback create_blob(tenant_id, content) :: {:ok, sha}
  @callback get_blob(tenant_id, sha) :: {:ok, blob}
  @callback create_tree(tenant_id, entries) :: {:ok, sha}
  # ... trees, commits, refs
end
```

Default: ETS (in-memory). Production: PostgreSQL, S3, etc.

---

# Deployment

```dockerfile
# Multi-stage build
FROM elixir:1.18 AS build
RUN curl -fsSL https://gleam.run/install.sh | sh  # Install Gleam
WORKDIR /app
COPY levee_protocol ./levee_protocol
RUN cd levee_protocol && gleam build --target erlang
COPY . .
RUN mix release

# Runtime
FROM debian:bookworm-slim
COPY --from=build /app/_build/prod/rel/levee ./
CMD ["bin/levee", "start"]
```

- Gleam compiles first → BEAM bytecode
- Mix bundles everything into OTP release
- **Bandit** serves HTTP/WebSocket on port 4000
- Supports DNS clustering for multi-node deployments

---

# Part 2: The Driver Layer

---

# Driver Purpose

The driver implements **Fluid Framework interfaces** to connect TypeScript applications to the Levee server

```
IDocumentServiceFactory  →  LeveeDocumentServiceFactory
IDocumentService         →  LeveeDocumentService
IDocumentDeltaConnection →  LeveeDeltaConnection
IDocumentStorageService  →  LeveeStorageService
IUrlResolver             →  LeveeUrlResolver
ITokenProvider           →  InsecureLeveeTokenProvider
                             RemoteLeveeTokenProvider
```

---

# Driver Architecture

```
LeveeDocumentServiceFactory
    │
    └── Creates: LeveeDocumentService
            │
            ├── LeveeDeltaConnection
            │   └── WebSocket for real-time ops
            │
            ├── LeveeStorageService
            │   └── REST for blobs/snapshots
            │
            └── LeveeDeltaStorageService
                └── REST for historical ops
```

---

# LeveeDocumentServiceFactory

**Entry point** - implements `IDocumentServiceFactory`

```typescript
class LeveeDocumentServiceFactory {
  constructor(tokenProvider: ITokenProvider)

  // Load existing document
  createDocumentService(resolvedUrl): Promise<IDocumentService>

  // Create new document
  createContainer(summary, resolvedUrl): Promise<IDocumentService>
}
```

On `createContainer`: POST to server → receive document ID → return service

---

# LeveeDocumentService

**Coordinates three connection types** required by Fluid Framework

```typescript
class LeveeDocumentService implements IDocumentService {
  // For snapshots and blobs
  connectToStorage(): Promise<LeveeStorageService>

  // For catching up on missed operations
  connectToDeltaStorage(): Promise<LeveeDeltaStorageService>

  // For real-time ops and signals
  connectToDeltaStream(): Promise<LeveeDeltaConnection>
}
```

---

# LeveeDeltaConnection

**Real-time bidirectional communication**

```typescript
interface LeveeDeltaConnection {
  clientId: string           // Assigned by server
  mode: "read" | "write"     // Connection mode
  existing: boolean          // Pre-existing document?
  maxMessageSize: number     // Server limit

  // Initial state received on connect
  initialMessages: ISequencedDocumentMessage[]
  initialSignals: ISignalMessage[]
  initialClients: ISignalClient[]

  // Methods
  submit(messages): void     // Send ops to server
  submitSignal(content): void
}
```

---

# Connection Lifecycle

```
1. Create WebSocket connection (with auth token)
         │
2. Join document channel
         │
3. Send connect_document message
         │
4. Receive connect_document_success
         │
         ├── clientId assigned
         ├── initialMessages (ops to catch up)
         ├── initialSignals
         └── initialClients (who's connected)
         │
5. Ready for real-time collaboration
```

---

# Message Buffering

Operations submitted before connection completes are **queued**

```
submit(op1)  ──┐
submit(op2)  ──┼──► Queue
submit(op3)  ──┘
                    │
    connect_document_success
                    │
                    ▼
              Flush queue
              to server
```

Prevents message loss during startup

---

# Storage Services

**LeveeStorageService** - Snapshots and blobs
```typescript
getVersions()                    // List available snapshots
getSnapshotTree(version)         // Get snapshot content
createBlob(content)              // Upload content
uploadSummaryWithContext(...)    // Save new snapshot
```

**LeveeDeltaStorageService** - Historical ops
```typescript
fetchMessages(from, to)          // Get ops in sequence range
// Batches in chunks of 2000
```

---

# Git-Compatible Storage

The server uses a **Git-like storage model**:

```typescript
class GitManager {
  // Content-addressable blobs
  getBlob(sha): Promise<GitBlob>
  createBlob(content): Promise<GitBlob>

  // Directory structure
  getTree(sha): Promise<GitTree>
  createTree(entries): Promise<GitTree>

  // Snapshot commits
  getCommit(sha): Promise<GitCommit>
  createCommit(message, tree, parents): Promise<GitCommit>
}
```

Enables versioned snapshots and efficient diffs

---

# URL Resolution

**LeveeUrlResolver** parses document URLs:

```
levee://host:port/tenantId/documentId
http://host:port/tenantId/documentId
```

**Produces:**
```typescript
{
  tenantId: string
  documentId: string
  socketUrl: "ws://host:4000/socket"
  httpUrl: "http://host:4000"
  endpoints: {
    deltaStorageUrl: "/deltas/{tenant}/{doc}"
    storageUrl: "/repos/{tenant}"
  }
}
```

---

# Authentication

**Two token types:**
- **Orderer Token** - WebSocket connection
- **Storage Token** - REST API calls

**Token claims:**
```typescript
{
  tenantId, documentId,
  scopes: ["doc:read", "doc:write", "summary:write"],
  user: { id, name },
  exp: /* expiration */
}
```

**Providers:** `InsecureLeveeTokenProvider` (dev) or `RemoteLeveeTokenProvider` (prod)

---

# Part 3: The Client Layer

---

# Client Purpose

**levee-client** provides a simplified API similar to `@fluidframework/fluid-static`

Hides driver complexity behind two methods:
- `createContainer()` - Create new collaborative document
- `getContainer()` - Load existing document

---

# Client Configuration

```typescript
const client = new LeveeClient({
  connection: {
    httpUrl: "http://localhost:4000",
    socketUrl: "ws://localhost:4000/socket",
    tenantId: "my-tenant",
    tenantKey: "secret-key",
    user: { id: "user-1", name: "Alice" }
  }
})
```

---

# Creating a Container

```typescript
const { container, services } = await client.createContainer(
  containerSchema,
  compatibilityMode
)

// Attach to server (creates document)
const containerId = await container.attach()

// Access shared objects
const myMap = container.initialObjects.myMap
```

---

# Loading a Container

```typescript
const { container, services } = await client.getContainer(
  "document-id-123",
  containerSchema,
  compatibilityMode
)

// Container is connected and synced
const myMap = container.initialObjects.myMap

// Track connected users
services.audience.on("memberAdded", (clientId, member) => {
  console.log(`${member.name} joined`)
})
```

---

# Container Services

```typescript
interface LeveeContainerServices {
  audience: ILeveeAudience
}

interface LeveeMember {
  id: string      // User ID
  name: string    // Display name
  connections: [] // Active connections
}
```

**Events:** `memberAdded`, `memberRemoved`

---

# Create Container Flow

```
client.createContainer(schema)
    │
    ▼
createDetachedContainer()
    │
    ▼
container.attach()
    │
    ▼
POST /documents/{tenantId}
    │
    ▼
Server creates document, returns ID
    │
    ▼
Connect WebSocket → Join channel
    │
    ▼
connect_document → connect_document_success
    │
    ▼
Container ready
```

---

# Load Container Flow

```
client.getContainer(documentId, schema)
    │
    ▼
Resolve URL
    │
    ▼
Connect to Storage → Fetch latest snapshot
    │
    ▼
Connect to Delta Storage → Fetch missed ops
    │
    ▼
Connect to Delta Stream (WebSocket)
    │
    ▼
Receive initial state, hydrate container
    │
    ▼
Container synced and ready
```

---

# Real-time Operation Flow

```
┌─────────────┐           ┌──────────────┐           ┌─────────────┐
│   Client A  │           │ Levee Server │           │   Client B  │
└──────┬──────┘           └──────┬───────┘           └──────┬──────┘
       │                         │                          │
       │  submitOp {op}          │                          │
       │────────────────────────>│                          │
       │                         │                          │
       │                    Assign sequence number          │
       │                         │                          │
       │    op {sequenced}       │    op {sequenced}        │
       │<────────────────────────│─────────────────────────>│
       │                         │                          │
```

All clients receive the same sequenced operation

---

# Error Handling

**Nack** - Server rejects an operation

```typescript
connection.on("nack", (nack) => {
  // nack.content.type: "ThrottlingError", "InvalidScopeError", etc.
  // nack.content.message: Human-readable error
  // nack.content.retryAfter: Optional retry delay
})
```

**Common reasons:**
- Rate limiting
- Permission denied
- Malformed request

---

# Summary: Layer Responsibilities

| Layer | Package | Responsibility |
|-------|---------|----------------|
| **Server** | Elixir/Gleam | Op sequencing, storage, auth |
| **Driver** | `levee-driver` | Fluid interfaces, protocol |
| **Client** | `levee-client` | High-level API, lifecycle |

---

# Key Design Points

1. **Three connection types** per document
   - Real-time (WebSocket)
   - Snapshots (REST)
   - History (REST)

2. **Git-compatible storage** for versioned snapshots

3. **Separation of orderer and storage tokens**

4. **Message buffering** during connection setup

5. **Fluid Framework compatibility** via standard interfaces

---

# Questions?

