---
marp: true
theme: gaia
paginate: true
title: Levee Architecture
author: Tyler Butler
backgroundColor: #1a1a2e
color: #e4e4e7
style: |
  section {
    font-size: 28px;
  }
  section.lead h1 {
    font-size: 60px;
  }
  section.lead h2 {
    font-size: 32px;
    color: #a1a1aa;
  }
  code {
    background-color: #2a2a3e;
  }
  pre {
    background-color: #12121e;
  }
  a {
    color: #7dd3fc;
  }
  table th {
    background-color: #2a2a3e;
  }
  .columns {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 1em;
  }
---

<!-- _class: lead -->

![w:200](levee.webp)

# Levee Architecture

## A Fluid Framework Service in Elixir/Gleam

Real-time collaborative applications with a functional backend

<!--
Welcome to the Levee architecture talk. Levee is a from-scratch implementation of a Fluid Framework service backend, built using Elixir and Gleam on the BEAM virtual machine. The goal is to explore what a collaborative editing backend looks like when built with functional, concurrent-first languages instead of the typical Node.js approach.
-->

---

# What is Levee?

**Levee** is a Fluid Framework-compatible service written in **Elixir** and **Gleam**

**Components:**

1. **Levee Server** - Elixir/Gleam backend service
2. **levee-driver** - TypeScript driver implementing Fluid interfaces
3. **levee-client** - High-level TypeScript API for applications

<!--
Levee has three main layers. The server handles all the real-time protocol logic — sequencing operations, managing sessions, storing snapshots. The driver is a TypeScript package that implements Fluid Framework's standard interfaces, so existing Fluid apps can connect to Levee with minimal changes. And the client package wraps the driver in a simpler API, similar to what fluid-static provides in the official Fluid ecosystem.
-->

---

# Why Elixir/Gleam?

- **Concurrency** - BEAM VM handles millions of lightweight processes
- **Fault tolerance** - "Let it crash" supervision trees
- **Real-time** - Built for WebSocket and persistent connections
- **Gleam** - Type-safe functional language, compiles to **Erlang and JavaScript**
  - JS target enables sharing protocol logic with TypeScript clients

Perfect fit for collaborative document services

<!--
The BEAM VM — the Erlang runtime — was designed from the ground up for telecoms: millions of concurrent connections, fault isolation, hot code reloading. A collaborative editing service is essentially the same problem: lots of concurrent users, each with their own WebSocket connection, and you need fault isolation so one document's crash doesn't take down others. Gleam adds compile-time type safety on top of BEAM, which is critical for getting the protocol logic right. And crucially, Gleam compiles to both Erlang and JavaScript — so the same protocol logic that runs on the server can be compiled to JS and shared with the TypeScript client packages. This means validation, message types, and sequencing rules are defined once and used on both sides.
-->

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

<!--
Here's the full stack. Your application sits at the top. It talks to levee-client, which handles lifecycle — creating and loading containers. Under that, levee-driver implements the Fluid Framework interfaces — the actual protocol. The driver communicates with the server over two channels: WebSocket for real-time operations and signals, and REST for snapshots, deltas, and git-like storage. The server runs on the BEAM VM with Elixir handling the runtime concerns and Gleam handling the protocol logic.
-->

---

<!-- _class: lead -->

![w:150](levee.webp)

# Part 1
## Levee Server

<!--
Let's dive into the server architecture. This is where the most interesting design decisions live.
-->

---

# Server Architecture

```
┌───────────────────────────────────────────────────┐
│  Elixir Layer (Runtime & Web)                     │
│  ┌──────────────┐ ┌──────────────┐ ┌───────────┐ │
│  │   Document   │ │ WebSocket /  │ │  Storage  │ │
│  │   Session    │ │  REST API    │ │ (ETS/PG)  │ │
│  └──────┬───────┘ └──────┬───────┘ └───────────┘ │
├─────────┼────────────────┼────────────────────────┤
│  Gleam Layer (Protocol Logic)                     │
│  Sequencing │ Signals │ Session │ Nack │ Auth     │
└───────────────────────────────────────────────────┘
                       BEAM VM
```

<!--
The server is split into two layers. The Elixir layer handles all runtime concerns: OTP supervision trees for fault tolerance, Phoenix for HTTP and WebSocket routing, and pluggable storage backends — ETS for development, PostgreSQL for production. The Gleam layer below it contains all the protocol logic: sequence number management, signal handling, session logic, nack generation, message types, and authentication. Both layers compile to BEAM bytecode and communicate with zero overhead.
-->

---

# Why Two Languages?

<div class="columns">
<div>

**Gleam** — Protocol Logic
- Type-safe state machines
- Compile-time guarantees
- No runtime type errors
- Exhaustive pattern matching

</div>
<div>

**Elixir** — Runtime
- OTP supervision trees
- Phoenix WebSocket/HTTP
- GenServer per document
- Production-ready ecosystem

</div>
</div>

Both compile to **BEAM bytecode** — zero-cost interop

<!--
Why use two languages in one project? Gleam gives us compile-time guarantees where we need them most — the protocol state machine. If you get sequence number logic wrong, clients desync. If you miss a message type in a pattern match, operations get dropped silently. Gleam's exhaustive pattern matching and result types make those bugs impossible. Elixir, on the other hand, gives us the full OTP ecosystem — supervision trees, Phoenix channels, mature libraries. Since both compile to BEAM bytecode, calling Gleam from Elixir is exactly like calling any Erlang module: no FFI, no serialization, no overhead.
-->

---

# Gleam Components Overview

<div class="columns">
<div>

**Protocol Core**
- `sequencing` — Sequence numbers
- `session_logic` — Session management
- `signals` — Signal targeting
- `message` — Message types
- `types` — Core Fluid types

</div>
<div>

**Validation & Auth**
- `validation` — Message validation
- `nack` — Error responses
- `jwt` — Token validation
- `summary` — Snapshot types
- `schema` — Schema generation

</div>
</div>

<!--
Here's the full layout of the Gleam protocol package. The key modules are sequencing, which handles the core causal ordering logic, signals which manages ephemeral signaling with v1/v2 format support and client targeting, and session_logic which contains the higher-level session management functions like feature negotiation and op building. There's also a schema module with a CLI entry point that generates JSON schemas from the Gleam types — we use this to generate TypeScript types for the client packages.
-->

---

# Gleam: Sequence Number Management

```rust
// The heart of collaborative editing — ensuring causal ordering

type SequenceState {
  SequenceState(
    sequence_number: Int,       // SN: Server-assigned global order
    min_sequence_number: Int,   // MSN: Minimum RSN across clients
    client_states: Dict(String, ClientSequenceState),
  )
}

type ClientSequenceState {
  ClientSequenceState(last_csn: Int, last_rsn: Int)
}

type SequenceResult {
  SequenceOk(state: SequenceState, assigned_sn: Int, msn: Int)
  SequenceError(reason: SequenceError)
}

fn assign_sequence_number(
  state: SequenceState, client_id: String, csn: Int, rsn: Int,
) -> SequenceResult
```

<!--
This is the heart of the system. Every operation submitted by any client gets a globally ordered sequence number. The SequenceState tracks three things: the current global sequence number, the minimum sequence number across all clients (used for garbage collection), and per-client state tracking their last CSN and RSN. The assign_sequence_number function validates the client's CSN is monotonically increasing, their RSN isn't from the future, and assigns the next global SN. It returns a SequenceResult — either SequenceOk with the new state and assigned SN, or a SequenceError explaining what went wrong.
-->

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

<!--
Four numbers govern the whole protocol. SN is assigned by the server and provides total ordering across all clients — this is what makes collaborative editing deterministic. CSN is the client's own counter, so the server can detect duplicate or out-of-order client submissions. RSN tells the server what the client has already seen, which is critical for garbage collection and catch-up. MSN is the minimum RSN across all connected clients — any operations before MSN can be safely garbage collected because all clients have acknowledged seeing them. All validation is enforced in Gleam at compile time.
-->

---

# Gleam: JWT Validation

Type-safe token validation with exhaustive error handling:

```rust
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

<!--
JWT validation is another area where Gleam's type safety pays off. Every possible failure mode is an explicit variant: expired token, wrong tenant, wrong document, missing scope, invalid claim. The Gleam compiler forces every caller to handle all five error cases. In a dynamically typed language, it's easy to forget to check for tenant mismatches and accidentally leak cross-tenant data. Here, the compiler won't let you.
-->

---

# Gleam: Message Types

Protocol messages as algebraic data types — pattern matching ensures exhaustive handling

<div class="columns">
<div>

```rust
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
  Control
}
```

</div>
<div>

```rust
type ConnectionMode {
  WriteMode
  ReadMode
}

type Scope {
  DocRead
  DocWrite
  SummaryWrite
}
```

</div>
</div>

<!--
All Fluid Framework message types are modeled as a single algebraic data type. When you pattern match on a MessageType in Gleam, the compiler will error if you forget to handle any variant. This is especially important as the protocol evolves — adding a new message type will cause compile errors everywhere it needs to be handled, rather than silently falling through to a default case. ConnectionMode similarly prevents accidentally allowing writes from read-only connections.
-->

---

# Gleam: Nack (Negative Acknowledgment)

Type-safe error responses when ops are rejected:

```rust
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
fn invalid_csn(client_id: String, expected: Int, got: Int) -> Nack
fn message_too_large(size: Int, max: Int) -> Nack
fn unknown_client(client_id: String) -> Nack
```

<!--
When the server needs to reject an operation, it sends a Nack — a negative acknowledgment. Each error type maps to an HTTP-like status code so clients can programmatically handle them. The constructor functions provide semantic, self-documenting ways to create nacks. For example, invalid_csn includes both the expected and actual values for debugging. read_only_client is used when a read-mode connection tries to submit an operation. The client receives these as structured objects, not opaque error strings.
-->

---

# Gleam: Signal Handling

Ephemeral signals with v1/v2 format support and client targeting:

```rust
type NormalizedSignal {
  NormalizedSignal(
    client_id: String,
    content: String,
    target_client_id: Option(String),  // Targeted delivery
  )
}

fn normalize_signal(raw: Dict) -> NormalizedSignal
fn should_client_receive_signal(envelope, client_id, sender_id) -> Bool
fn get_signal_recipients(envelope, all_clients, sender_id) -> List(String)
```

Supports both broadcast and targeted signal delivery

<!--
Signals are ephemeral messages — things like cursor positions, selection highlights, or typing indicators. Unlike operations, they're not sequenced or persisted. Levee supports two signal formats: v1 which is a simple broadcast, and v2 which adds client targeting — you can send a signal to a specific client or exclude certain clients. The normalize_signal function auto-detects the format and converts to a unified internal representation. The targeting logic determines which clients should receive each signal, which is important for features like "show my cursor only to the person I'm collaborating with."
-->

---

# Gleam: Validation Functions

Composable validation with clear error types:

```rust
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

<!--
Validation functions are composable — they all return Result types, so you can chain them with Gleam's use syntax. Each validates one concern: message size limits prevent abuse, write mode check ensures read-only clients can't submit ops, and scope validation enforces fine-grained permissions. Because they return typed errors, the calling code always knows exactly what went wrong and can generate the appropriate nack response.
-->

---

# Why Gleam for Protocol Logic?

<div class="columns">
<div>

**Correctness by construction**
- Invalid states are unrepresentable
- Compiler catches protocol violations

**Exhaustive pattern matching**
- Handle every message type
- No forgotten error cases

</div>
<div>

**Immutable state machines**
- Sequence state can't be corrupted
- Easy to reason about transitions

**Zero-cost BEAM interop**
- Call from Elixir like any Erlang module
- No serialization overhead

</div>
</div>

<!--
To summarize the Gleam story: it's about making bugs impossible rather than just unlikely. You can't construct an invalid SequenceState. You can't forget to handle a message type. You can't accidentally mutate state. And all of this comes at zero runtime cost — it's just BEAM bytecode. The compile-time checking doesn't add any overhead. If you're building something where correctness matters — and a collaborative editing protocol definitely qualifies — this is a powerful approach.
-->

---

# Elixir Ecosystem Components

| Component | Library | Purpose |
|-----------|---------|---------|
| HTTP Server | **Bandit** | Pure-Elixir HTTP/2 server |
| Web Framework | **Phoenix** | Channels, routing, controllers |
| JWT | **JOSE** | Token signing and verification |
| Clustering | **libcluster** | DNS-based node discovery |
| PubSub | **Phoenix.PubSub** | Inter-process message broadcast |
| Storage | **ETS / PostgreSQL** | Pluggable backends |

All battle-tested, production-grade libraries

<!--
On the Elixir side, we're standing on the shoulders of very mature libraries. Bandit is a pure-Elixir HTTP server that handles HTTP/1.1, HTTP/2, and WebSocket. Phoenix provides the routing and channel infrastructure. JOSE handles JWT cryptography. libcluster enables multi-node deployments with automatic node discovery. Storage is pluggable — ETS for development gives you an in-memory backend that's fast and needs no setup, while the PostgreSQL backend via the Gleam levee_storage package provides durability for production.
-->

---

# Elixir: Application Structure

```
lib/levee/
├── application.ex           # OTP app, supervision tree
├── auth/
│   ├── jwt.ex              # JOSE JWT signing/verification
│   ├── tenant_secrets.ex   # Tenant registration & secrets
│   ├── gleam_bridge.ex     # Gleam auth interop (users, sessions, etc.)
│   └── session_store_supervisor.ex
├── documents/
│   ├── session.ex          # GenServer per document
│   ├── registry.ex         # Session lookup
│   └── supervisor.ex       # Dynamic supervisor
├── protocol/
│   └── bridge.ex           # Gleam protocol interop wrapper
├── storage/
│   ├── behaviour.ex        # Storage interface
│   ├── gleam_ets.ex        # In-memory backend (dev)
│   └── gleam_pg.ex         # PostgreSQL backend (prod)
└── oauth/
    └── state_store_supervisor.ex
```

<!--
Here's the Elixir application structure. The auth directory has grown significantly — gleam_bridge.ex wraps the Gleam levee_auth package, providing idiomatic Elixir access to password hashing, user management, session management, tenant operations, and token minting. Documents still follows the same pattern: a dynamic supervisor spawns a GenServer per document. Storage now has two backends — gleam_ets for development and gleam_pg for PostgreSQL in production, both implementing the same behaviour. The OAuth directory is new, supporting GitHub OAuth for the admin UI and user-facing auth.
-->

---

# Elixir: Document Session

One **GenServer process per document** — isolation and concurrency

```elixir
defmodule Levee.Documents.Session do
  use GenServer

  defstruct [:document_id, :sequence_state, :connected_clients,
             :operation_history, :pending_summaries]

  def handle_call({:submit_op, client_id, op}, _from, state) do
    case Protocol.Bridge.assign_sequence_number(...) do
      {:ok, new_state, seq_num} -> ...
      {:error, reason} -> ...
    end
  end
end
```

<!--
Each document gets its own GenServer process — this is the OTP model for isolation. If one document's process crashes, it doesn't affect any other documents. The session struct holds the Gleam SequenceState, the list of connected clients, a rolling history of the last 1000 operations for catch-up when new clients join, and any pending summary operations. When an operation comes in, the GenServer calls into the Gleam sequencing module to assign a sequence number. If it succeeds, the sequenced operation gets broadcast to all connected clients via Phoenix PubSub.
-->

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

<!--
The Protocol Bridge module is the glue between Elixir and Gleam. Gleam modules compile to Erlang modules with names like colon-levee_protocol-at-sequencing. The bridge wraps these calls with idiomatic Elixir patterns — converting Gleam result tuples, normalizing error types, and providing a clean API for the rest of the Elixir codebase. There's also a separate auth bridge — gleam_bridge.ex in the auth directory — that wraps the Gleam auth module for user management, sessions, and token operations.
-->

---

# Elixir: Web Layer (Phoenix)

```
lib/levee_web/
├── router.ex                    # Route definitions
├── channels/
│   └── document_channel.ex      # Phoenix Channel for real-time
├── controllers/
│   ├── document_controller.ex   # Document CRUD
│   ├── delta_controller.ex      # Historical operations
│   ├── git_controller.ex        # Git-like blob/tree/commit
│   ├── token_mint_controller.ex # Session → JWT minting
│   ├── auth_controller.ex       # Register, login, logout
│   ├── oauth_controller.ex      # GitHub OAuth flow
│   ├── health_controller.ex     # Health check
│   └── admin_controller.ex      # Admin UI SPA
└── plugs/
    ├── auth.ex                  # JWT middleware
    ├── session_auth.ex          # Session token middleware
    └── admin_auth.ex            # Admin key middleware
```

<!--
The web layer has grown considerably. Beyond the core Fluid protocol controllers for documents, deltas, and git storage, there are now controllers for authentication — both traditional register/login and GitHub OAuth — plus a token-mint controller that bridges session auth to document JWTs. The plugs directory reflects the two auth systems: JWT auth for document operations, session auth for user-facing APIs, and admin auth using a server-side secret key for administrative operations. Each plug is composable in Phoenix's pipeline architecture.
-->

---

# Server API

| Protocol | Endpoint | Purpose |
|----------|----------|---------|
| REST | `/documents/{tenantId}` | Create/get documents |
| REST | `/repos/{tenantId}/git/*` | Blob/tree/commit storage |
| REST | `/deltas/{tenantId}/{docId}` | Historical operations |
| REST | `/api/auth/*` | Register, login, logout |
| REST | `/api/tenants/:tid/token-mint` | Mint document JWTs |
| REST | `/auth/:provider` | OAuth flow |
| REST | `/health` | Health check |
| WebSocket | `/socket` | Real-time connection |

<!--
The server exposes several API surfaces. The core Fluid protocol APIs — documents, repos, deltas, and WebSocket — are all authenticated with JWTs scoped to specific tenants and documents. The user auth APIs under /api/auth handle registration, login, and session management. The token-mint endpoint is the bridge between the two auth systems — a logged-in user can mint document JWTs for their tenant. OAuth handles GitHub login flows. The health endpoint is unauthenticated for load balancer probes.
-->

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

<!--
The real-time protocol uses Phoenix Channels over WebSocket. Each document gets its own channel topic. The lifecycle starts with connect_document, where the client sends its capabilities and token. The server responds with connect_document_success, which includes the assigned client ID, any initial messages for catch-up, the list of currently connected clients, and the server's service configuration. After that, it's a steady state of submitOp/op for operations and submitSignal/signal for ephemeral data. Nacks are sent back to individual clients when their operations are rejected.
-->

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

<!--
Let's trace a single operation through the system. A client submits an op with its CSN and RSN. The DocumentChannel in Phoenix receives it and first validates the JWT token via the Gleam JWT module. If the token is valid, the op goes to the Session GenServer, which calls the Gleam sequencing module to assign the next global sequence number. This validates CSN ordering, checks RSN isn't from the future, and updates the sequence state. If everything checks out, the sequenced operation is broadcast to all clients on the channel — including the sender, so they know their op was accepted.
-->

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

<!--
These are the key server configuration values. Max message size of 16KB prevents individual operations from being too large. Block size of 64KB limits blob uploads. The summary configuration controls when snapshots are taken: after 5 seconds of idle time, after 1000 operations, or with a 10-minute maximum wait for summary acknowledgments. The server keeps the last 1000 operations in memory per document, which allows new clients to catch up without needing to read from storage in most cases.
-->

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

**Backends:** ETS (in-memory, dev) and PostgreSQL (via Gleam `levee_storage`)

<!--
Storage is abstracted behind an Elixir behaviour — essentially an interface. Any backend that implements these callbacks can be swapped in. The ETS backend stores everything in-memory, which is perfect for development — zero setup, instant startup, and fast. The PostgreSQL backend, implemented in the Gleam levee_storage package, provides durability for production. Both backends implement the full interface including git-like content-addressable storage for blobs, trees, commits, and refs. The git model enables efficient snapshot versioning and diff computation.
-->

---

# Gleam Packages

Five Gleam packages provide the type-safe core:

| Package | Purpose |
|---------|---------|
| **levee_protocol** | Message types, sequencing, validation, signals, nacks |
| **levee_auth** | JWT, password hashing, users, sessions, tenants |
| **levee_storage** | Storage types, ETS backend, PostgreSQL backend |
| **levee_oauth** | OAuth provider integration (GitHub) |
| **levee_admin** | Lustre SPA for admin dashboard |

All compile to BEAM bytecode and are called from Elixir via bridge modules

<!--
The Gleam code is organized into five packages. levee_protocol is the largest, containing all the Fluid Framework protocol logic. levee_auth handles everything authentication-related — not just JWTs, but also user management, password hashing, session management, and tenant operations. levee_storage provides the storage abstraction with both ETS and PostgreSQL backends implemented in Gleam using the bravo library for typed ETS access. levee_oauth is newer, handling the OAuth provider integration. And levee_admin is a Lustre single-page application for the admin dashboard. Each package is called from Elixir through dedicated bridge modules.
-->

---

# Deployment: Build

```dockerfile
# Multi-stage build
FROM elixir:1.18 AS build
RUN curl -fsSL https://gleam.run/install.sh | sh
WORKDIR /app
COPY levee_protocol ./levee_protocol
RUN cd levee_protocol && gleam build --target erlang
COPY . .
RUN mix release

FROM debian:bookworm-slim
COPY --from=build /app/_build/prod/rel/levee ./
CMD ["bin/levee", "start"]
```

<!--
Deployment is a multi-stage Docker build. Gleam compiles first, producing BEAM bytecode that gets placed where Mix can find it. Then Mix compiles the Elixir code and produces an OTP release — a self-contained bundle that includes everything needed to run. The runtime image is minimal Debian, keeping the final image small.
-->

---

# Deployment: Runtime

- Gleam compiles first → BEAM bytecode
- Mix bundles everything into an **OTP release**
- **Bandit** serves HTTP/WebSocket on port 4000
- **libcluster** for DNS-based node discovery
- **Phoenix PubSub** broadcasts ops across nodes

```
┌──────────┐    ┌──────────┐    ┌──────────┐
│  Node 1  │◄──►│  Node 2  │◄──►│  Node 3  │
│ :4000    │    │ :4000    │    │ :4000    │
└──────────┘    └──────────┘    └──────────┘
      ▲  DNS cluster discovery + PubSub
```

<!--
In production, Bandit serves both HTTP and WebSocket on port 4000. For multi-node deployments, libcluster handles automatic node discovery via DNS — nodes find each other without manual configuration. Phoenix PubSub ensures that when an operation is sequenced on one node, it gets broadcast to clients connected to any node. This gives you horizontal scalability — just add more nodes behind a load balancer.
-->

---

<!-- _class: lead -->

![w:150](levee.webp)

# Part 2
## The Driver Layer

<!--
Now let's look at the TypeScript driver that connects client applications to the Levee server.
-->

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

<!--
The driver's job is to make Levee look like any other Fluid Framework service to the client runtime. It implements six standard Fluid interfaces. The key insight is that by implementing these interfaces, any existing Fluid Framework application can switch to Levee by just changing the service factory — no other code changes needed. InsecureLeveeTokenProvider is for development — it signs tokens locally with a shared secret. RemoteLeveeTokenProvider is for production — it calls the token-mint endpoint to get properly scoped JWTs.
-->

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

<!--
When the Fluid runtime requests a document service, the factory creates a LeveeDocumentService which coordinates three connection types. The DeltaConnection handles the WebSocket for real-time operations and signals. The StorageService handles REST calls for blob and snapshot storage. And the DeltaStorageService handles REST calls for fetching historical operations. This three-connection model is a Fluid Framework design pattern — it separates the real-time hot path from the storage cold path.
-->

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

<!--
The factory is the entry point. It takes a token provider — either the insecure one for dev or the remote one for production. createDocumentService loads an existing document, while createContainer creates a new one. When creating, it POSTs an initial summary to the server's document endpoint, gets back a document ID, and then creates the document service. The factory handles URL resolution, token acquisition, and service instantiation.
-->

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

<!--
The document service is a coordinator. The Fluid runtime calls these three methods to establish all the connections it needs. connectToStorage provides access to snapshots and blobs — the persistent state. connectToDeltaStorage provides access to historical operations — used for catch-up when loading a document. connectToDeltaStream establishes the WebSocket connection for real-time collaboration. Each returns a Promise because connection establishment is asynchronous.
-->

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

<!--
The DeltaConnection is where the real-time magic happens. After connecting, the server assigns a clientId and sends back initial state — any messages the client needs for catch-up, current signals, and the list of connected clients. The mode field reflects whether this client has write access. maxMessageSize tells the client the server's limit so it can validate locally before sending. The submit method sends operations, and submitSignal sends ephemeral signals. Both are fire-and-forget — if there's a problem, the server sends back a nack.
-->

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

<!--
The connection lifecycle has five steps. First, the WebSocket connection is established with the auth token in the connection params. Then the client joins the document-specific channel. It sends a connect_document message with its client capabilities and version information. The server responds with connect_document_success, which includes the assigned client ID, any operations the client needs to catch up on, current signals, and the list of connected clients. After processing the initial state, the client is ready for real-time collaboration.
-->

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

<!--
This is a subtle but important detail. The Fluid runtime may start submitting operations before the WebSocket connection is fully established. Without buffering, those operations would be lost. The driver maintains an internal queue that collects operations during startup. Once connect_document_success is received and the connection is ready, the queue is flushed to the server in order. This ensures no operations are lost during the connection handshake, which is critical for data integrity.
-->

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

<!--
The storage services handle the persistent data. LeveeStorageService manages snapshots — the full state of the document at a point in time — and blobs, which are content-addressable chunks of data. uploadSummaryWithContext is called when the Fluid runtime wants to create a new snapshot, which happens based on the server's summary configuration. LeveeDeltaStorageService fetches historical operations, which is needed when loading a document that has operations since the last snapshot. It batches requests in chunks of 2000 to avoid overwhelming the server.
-->

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

<!--
The storage model is inspired by Git. Blobs are content-addressable — the same content always produces the same SHA, which enables deduplication. Trees represent directory structures, pointing to blobs and other trees. Commits point to trees and have parent pointers, creating a history. This model is a natural fit for document snapshots — each snapshot is a commit pointing to a tree of blobs, and you can efficiently diff between snapshots by comparing trees. It's the same model that Fluid Framework's reference implementation uses, which made compatibility straightforward.
-->

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

<!--
URL resolution converts a document URL into all the connection parameters the driver needs. It supports both a custom levee:// scheme and standard http:// URLs. The resolver extracts the tenant and document IDs and computes the WebSocket URL, HTTP base URL, and specific endpoint paths for delta storage and blob storage. This is a Fluid Framework pattern — the URL resolver provides a layer of indirection so the same driver code works regardless of how the service is deployed.
-->

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

<!--
The Fluid Framework expects two types of tokens: orderer tokens for the WebSocket connection and storage tokens for REST API calls. Both contain the same claims — tenant ID, document ID, scopes, user info, and expiration. The scopes control what the client can do: doc:read for reading, doc:write for submitting operations, and summary:write for creating snapshots. InsecureLeveeTokenProvider signs tokens locally with a shared secret — great for development. RemoteLeveeTokenProvider calls the server's token-mint endpoint, which requires a valid user session.
-->

---

# Two Auth Systems

Levee has two independent authentication systems:

```
┌─────────────────────────────────────────────────────────────┐
│ 1. USER AUTH (sessions)                                     │
│    GitHub OAuth → session token (ses_xxx)                    │
│    Used for: Admin UI, /api/auth/* routes                   │
│                                                             │
│ 2. DOCUMENT AUTH (JWTs)                                     │
│    Signed with tenant secret (HS256)                        │
│    Used for: /documents/*, /deltas/*, /repos/*, WebSocket   │
│    Claims: {tenantId, documentId, scopes, user, exp}        │
└─────────────────────────────────────────────────────────────┘
```

<!--
This is an important architectural decision. User auth and document auth are completely separate systems. User auth handles "who is this person" — login via GitHub OAuth, session management, the admin UI. It uses opaque session tokens prefixed with ses_. Document auth handles "can this client access this document" — it uses signed JWTs with specific tenant, document, and scope claims. This separation means the Fluid protocol layer has no concept of user sessions, and the admin layer has no concept of document JWTs. Each system validates independently.
-->

---

# Token-Mint: Bridging Auth Systems

`POST /api/tenants/:tenant_id/token-mint` bridges session auth → document JWTs

```
 User's App                       Levee Server
 ─────────                        ────────────

 1. User logs in via              GitHub OAuth callback
    GitHub OAuth            ───►  creates session (ses_xxx)

 2. App opens a Fluid doc         LeveeClient created with
    in the app                    RemoteLeveeTokenProvider

 3. RemoteLeveeTokenProvider      POST /api/tenants/:tid/token-mint
    needs a document JWT    ───►  Authorization: Bearer ses_xxx
                                  Body: {documentId, scopes}

 4. Server validates:             SessionAuth plug
    - session token valid?        ✓ extracts current_user
    - user member of tenant?      ✓ checks Membership
    - scopes allowed for role?    ✓ filters by role

 5. Server mints JWT              token.create_document_token()
    with tenant secret      ───►  signs with tenant's HS256 key

 6. Returns {jwt, expiresIn}      Client caches and uses for
                                  WebSocket + REST operations
```

<!--
The token-mint endpoint is the bridge between the two auth systems. When a user opens a collaborative document in the app, the RemoteLeveeTokenProvider sends the user's session token to the token-mint endpoint. The server validates the session, checks that the user is a member of the requested tenant, filters the requested scopes based on the user's role in that tenant, and then mints a JWT signed with the tenant's secret key. The client caches this JWT and uses it for all subsequent document operations. This flow ensures that document JWTs are always properly scoped and that users can only access tenants they belong to.
-->

---

# Token-Mint: Components

| Component | Status | Notes |
|-----------|--------|-------|
| `SessionAuth` plug | Exists | Validates session token, sets `current_user` |
| `token.create_document_token/5` | Exists | Gleam function, mints JWT with scopes |
| `scopes.filter_for_role/2` | Exists | Filters scopes by role |
| `TenantSecrets.get_secrets/1` | Exists | Gets tenant signing key |
| `TokenMintController` | Exists | `POST /api/tenants/:tid/token-mint` |
| `RemoteLeveeTokenProvider` | Exists | Sends session token as Bearer header |
| `LeveeClient` | Exists | `authToken` config auto-creates provider |

**Client usage:**
```typescript
const client = new LeveeClient({
  tenantId: "my-tenant",
  authToken: sessionToken, // from OAuth login
  // auto-constructs RemoteLeveeTokenProvider
  // pointed at /api/tenants/{tenantId}/token-mint
});
```

<!--
All the components for the token-mint flow are implemented. SessionAuth is a Plug that validates session tokens. The Gleam token module mints JWTs, and the scopes module filters based on role. On the client side, LeveeClient has a convenient authToken config option that automatically constructs a RemoteLeveeTokenProvider pointed at the right endpoint. This means end users just need to pass their session token and everything else is handled automatically.
-->

---

<!-- _class: lead -->

![w:150](levee.webp)

# Part 3
## The Client Layer

<!--
Finally, let's look at the high-level client API that application developers interact with directly.
-->

---

# Client Purpose

**levee-client** provides a simplified API similar to `@fluidframework/fluid-static`

Hides driver complexity behind two methods:
- `createContainer()` - Create new collaborative document
- `getContainer()` - Load existing document

<!--
The client package exists because the driver layer, while powerful, is too low-level for most application developers. It mirrors the API of Fluid Framework's fluid-static package, which means developers familiar with Fluid can get started immediately. Two methods cover the two main use cases: creating a new collaborative document and loading an existing one. Everything else — token management, connection lifecycle, service coordination — is handled internally.
-->

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

<!--
For development, configuration is straightforward — you provide the server URLs, tenant credentials, and user info. The tenantKey is the shared secret used by InsecureLeveeTokenProvider to sign tokens locally. For production, you'd use the authToken config instead, which switches to RemoteLeveeTokenProvider and the token-mint flow. The user object is embedded in tokens and used for presence — other clients can see who's connected and display names.
-->

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

<!--
Creating a container is a two-step process. First, createContainer returns a detached container — it exists locally but hasn't been persisted to the server yet. The schema defines what shared objects the container holds — SharedMaps, SharedStrings, etc. Then container.attach() sends the initial summary to the server, which creates the document and returns an ID. After attach, the container is live and any changes to shared objects are automatically synced to other clients. The containerId is what you'd store in your app's database to reference this document later.
-->

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

<!--
Loading is simpler — you just provide the document ID and schema. The client handles fetching the latest snapshot, catching up on missed operations, and establishing the real-time connection. Once getContainer resolves, the container is fully synced and ready. The services object includes an audience tracker that emits events when users join or leave, which you can use to show a "who's online" indicator or presence avatars.
-->

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

<!--
Container services currently include the audience, which tracks connected users. Each member has an ID, display name, and a list of active connections — a single user might have multiple browser tabs open. The memberAdded and memberRemoved events fire when users connect and disconnect. This is built on top of Phoenix's presence tracking, which uses CRDTs to handle node failures gracefully in multi-node deployments.
-->

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

<!--
Here's the full create flow. createContainer calls the Fluid runtime's createDetachedContainer, which builds the in-memory container structure. When you call attach, it POSTs the initial summary to the server, which creates the document in storage and returns a document ID. Then it establishes the WebSocket connection, joins the document channel, and sends the connect_document handshake. Once the server responds with connect_document_success, the container is fully online and ready for real-time collaboration.
-->

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

<!--
The load flow is a multi-step catch-up process. First, the URL is resolved to get all the connection parameters. Then the storage service fetches the latest snapshot — this is the bulk of the document state. Next, the delta storage service fetches any operations that happened since that snapshot. Then the WebSocket connection is established for real-time updates. The Fluid runtime hydrates the container by applying the snapshot and then replaying the missed operations. Once everything is applied, the container is synced and ready.
-->

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

<!--
This diagram shows the steady-state operation flow. Client A submits an operation. The server assigns a global sequence number. Then the sequenced operation is broadcast to ALL clients — including Client A. This is important: the client doesn't apply its own operation locally until it receives the sequenced version back from the server. This ensures all clients see operations in exactly the same order, which is what makes the collaborative editing deterministic and convergent.
-->

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

<!--
When something goes wrong, the server sends a nack back to the specific client whose operation was rejected. The nack includes a structured error type that the client can programmatically handle, a human-readable message for logging, and optionally a retryAfter value for rate-limiting scenarios. The Fluid runtime handles nacks internally — for recoverable errors like throttling, it retries automatically. For non-recoverable errors like permission denied, it surfaces the error to the application.
-->

---

# Summary: Layer Responsibilities

| Layer | Package | Responsibility |
|-------|---------|----------------|
| **Server** | Elixir/Gleam | Op sequencing, storage, auth |
| **Driver** | `levee-driver` | Fluid interfaces, protocol |
| **Client** | `levee-client` | High-level API, lifecycle |

<!--
To wrap up, the three layers have clear separation of concerns. The server is the source of truth — it sequences operations, manages storage, and handles authentication. The driver implements the Fluid Framework interfaces, translating between the Fluid runtime's expectations and Levee's protocol. The client provides the developer-friendly API, hiding the complexity of connection management, token lifecycle, and service coordination.
-->

---

# Key Design Points

1. **Three connection types** per document
   - Real-time (WebSocket)
   - Snapshots (REST)
   - History (REST)

2. **Git-compatible storage** for versioned snapshots

3. **Separation of orderer and storage tokens**

4. **Token-mint** bridges user auth (sessions) and document auth (JWTs)

5. **Message buffering** during connection setup

6. **Fluid Framework compatibility** via standard interfaces

<!--
These are the key architectural decisions. Three connection types separate the real-time hot path from storage, allowing independent scaling. Git-compatible storage enables efficient versioning. Token separation follows the principle of least privilege. Token-mint bridges the user-facing auth with the document-level auth cleanly. Message buffering prevents data loss during startup. And Fluid Framework compatibility means existing Fluid apps can adopt Levee with minimal changes. Together, these decisions create a system that's both robust and practical.
-->

---

<!-- _class: lead -->

![w:150](levee.webp)

# Questions?

<!--
Thanks for listening. I'm happy to dive deeper into any area — the Gleam protocol implementation, the OTP supervision architecture, the Fluid Framework integration, or anything else that caught your interest.
-->
