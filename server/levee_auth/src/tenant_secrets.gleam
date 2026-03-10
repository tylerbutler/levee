//// In-memory store for tenant secrets management.
////
//// Manages tenant registration and secrets for JWT signing and verification.
//// Each tenant has a server-generated ID, a name, and two rotating secrets.

import gleam/bit_array
import gleam/crypto
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/otp/actor
import gleam/string

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

pub type TenantData {
  TenantData(name: String, secret1: String, secret2: String)
}

pub type TenantInfo {
  TenantInfo(id: String, name: String)
}

pub type TenantWithSecrets {
  TenantWithSecrets(id: String, name: String, secret1: String, secret2: String)
}

pub type SecretSlot {
  Slot1
  Slot2
}

pub type TenantSecretsError {
  TenantNotFound
  InvalidSlot
}

// ---------------------------------------------------------------------------
// Messages
// ---------------------------------------------------------------------------

pub type Message {
  CreateTenant(
    name: String,
    reply_to: Subject(Result(TenantWithSecrets, TenantSecretsError)),
  )
  GetTenant(
    id: String,
    reply_to: Subject(Result(TenantInfo, TenantSecretsError)),
  )
  GetSecrets(
    id: String,
    reply_to: Subject(Result(#(String, String), TenantSecretsError)),
  )
  GetSecret(id: String, reply_to: Subject(Result(String, TenantSecretsError)))
  RegenerateSecret(
    id: String,
    slot: SecretSlot,
    reply_to: Subject(Result(String, TenantSecretsError)),
  )
  RegisterTenant(id: String, secret: String, reply_to: Subject(Nil))
  UnregisterTenant(id: String, reply_to: Subject(Nil))
  TenantExists(id: String, reply_to: Subject(Bool))
  ListTenants(reply_to: Subject(List(String)))
  ListTenantsWithNames(reply_to: Subject(List(TenantInfo)))
  Shutdown(reply_to: Subject(Nil))
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

type State {
  State(tenants: Dict(String, TenantData))
}

// ---------------------------------------------------------------------------
// FFI
// ---------------------------------------------------------------------------

@external(erlang, "tenant_secrets_ffi", "generate_tenant_id")
fn generate_tenant_id(existing_keys: List(String)) -> String

@external(erlang, "tenant_secrets_ffi", "get_env")
fn get_env(name: String) -> Result(String, Nil)

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Start the tenant secrets actor.
pub fn start() -> Result(Subject(Message), actor.StartError) {
  actor.new_with_initialiser(5000, fn(subject) {
    let initial_tenants = init_from_env()
    actor.initialised(State(tenants: initial_tenants))
    |> actor.returning(subject)
    |> Ok
  })
  |> actor.on_message(handle_message)
  |> actor.start
  |> extract_subject
}

/// Create a new tenant with a generated ID and two secrets.
pub fn create_tenant(
  actor: Subject(Message),
  name: String,
) -> Result(TenantWithSecrets, TenantSecretsError) {
  process.call(actor, 5000, fn(reply_to) { CreateTenant(name:, reply_to:) })
}

/// Get tenant info (id, name) without secrets.
pub fn get_tenant(
  actor: Subject(Message),
  id: String,
) -> Result(TenantInfo, TenantSecretsError) {
  process.call(actor, 5000, fn(reply_to) { GetTenant(id:, reply_to:) })
}

/// Get both secrets for a tenant.
pub fn get_secrets(
  actor: Subject(Message),
  id: String,
) -> Result(#(String, String), TenantSecretsError) {
  process.call(actor, 5000, fn(reply_to) { GetSecrets(id:, reply_to:) })
}

/// Get secret1 for a tenant (backward-compatible).
pub fn get_secret(
  actor: Subject(Message),
  id: String,
) -> Result(String, TenantSecretsError) {
  process.call(actor, 5000, fn(reply_to) { GetSecret(id:, reply_to:) })
}

/// Regenerate one of a tenant's secrets.
pub fn regenerate_secret(
  actor: Subject(Message),
  id: String,
  slot: SecretSlot,
) -> Result(String, TenantSecretsError) {
  process.call(actor, 5000, fn(reply_to) {
    RegenerateSecret(id:, slot:, reply_to:)
  })
}

/// Register a tenant with an explicit ID and secret.
pub fn register_tenant(
  actor: Subject(Message),
  id: String,
  secret: String,
) -> Nil {
  process.call(actor, 5000, fn(reply_to) {
    RegisterTenant(id:, secret:, reply_to:)
  })
}

/// Unregister a tenant by ID.
pub fn unregister_tenant(actor: Subject(Message), id: String) -> Nil {
  process.call(actor, 5000, fn(reply_to) { UnregisterTenant(id:, reply_to:) })
}

/// Check if a tenant exists.
pub fn tenant_exists(actor: Subject(Message), id: String) -> Bool {
  process.call(actor, 5000, fn(reply_to) { TenantExists(id:, reply_to:) })
}

/// List all tenant IDs.
pub fn list_tenants(actor: Subject(Message)) -> List(String) {
  process.call(actor, 5000, fn(reply_to) { ListTenants(reply_to:) })
}

/// List all tenants with their names.
pub fn list_tenants_with_names(actor: Subject(Message)) -> List(TenantInfo) {
  process.call(actor, 5000, fn(reply_to) { ListTenantsWithNames(reply_to:) })
}

/// Generate a cryptographically secure 32-byte hex secret.
pub fn generate_secret() -> String {
  crypto.strong_random_bytes(32)
  |> bit_array.base16_encode
  |> string.lowercase
}

// ---------------------------------------------------------------------------
// Message handler
// ---------------------------------------------------------------------------

fn handle_message(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    CreateTenant(name:, reply_to:) -> {
      let existing_keys = dict.keys(state.tenants)
      let id = generate_tenant_id(existing_keys)
      let secret1 = generate_secret()
      let secret2 = generate_secret()
      let data = TenantData(name:, secret1:, secret2:)
      let new_tenants = dict.insert(state.tenants, id, data)
      process.send(
        reply_to,
        Ok(TenantWithSecrets(id:, name:, secret1:, secret2:)),
      )
      actor.continue(State(tenants: new_tenants))
    }

    GetTenant(id:, reply_to:) -> {
      let result = case dict.get(state.tenants, id) {
        Error(Nil) -> Error(TenantNotFound)
        Ok(data) -> Ok(TenantInfo(id:, name: data.name))
      }
      process.send(reply_to, result)
      actor.continue(state)
    }

    GetSecrets(id:, reply_to:) -> {
      let result = case dict.get(state.tenants, id) {
        Error(Nil) -> Error(TenantNotFound)
        Ok(data) -> Ok(#(data.secret1, data.secret2))
      }
      process.send(reply_to, result)
      actor.continue(state)
    }

    GetSecret(id:, reply_to:) -> {
      let result = case dict.get(state.tenants, id) {
        Error(Nil) -> Error(TenantNotFound)
        Ok(data) -> Ok(data.secret1)
      }
      process.send(reply_to, result)
      actor.continue(state)
    }

    RegenerateSecret(id:, slot:, reply_to:) -> {
      case dict.get(state.tenants, id) {
        Error(Nil) -> {
          process.send(reply_to, Error(TenantNotFound))
          actor.continue(state)
        }
        Ok(data) -> {
          let new_secret = generate_secret()
          let new_data = case slot {
            Slot1 -> TenantData(..data, secret1: new_secret)
            Slot2 -> TenantData(..data, secret2: new_secret)
          }
          let new_tenants = dict.insert(state.tenants, id, new_data)
          process.send(reply_to, Ok(new_secret))
          actor.continue(State(tenants: new_tenants))
        }
      }
    }

    RegisterTenant(id:, secret:, reply_to:) -> {
      let data =
        TenantData(name: id, secret1: secret, secret2: generate_secret())
      let new_tenants = dict.insert(state.tenants, id, data)
      process.send(reply_to, Nil)
      actor.continue(State(tenants: new_tenants))
    }

    UnregisterTenant(id:, reply_to:) -> {
      let new_tenants = dict.delete(state.tenants, id)
      process.send(reply_to, Nil)
      actor.continue(State(tenants: new_tenants))
    }

    TenantExists(id:, reply_to:) -> {
      process.send(reply_to, dict.has_key(state.tenants, id))
      actor.continue(state)
    }

    ListTenants(reply_to:) -> {
      process.send(reply_to, dict.keys(state.tenants))
      actor.continue(state)
    }

    ListTenantsWithNames(reply_to:) -> {
      let tenants =
        state.tenants
        |> dict.to_list
        |> list.map(fn(entry) {
          let #(id, data) = entry
          TenantInfo(id:, name: data.name)
        })
      process.send(reply_to, tenants)
      actor.continue(state)
    }

    Shutdown(reply_to:) -> {
      process.send(reply_to, Nil)
      actor.stop()
    }
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Extract the Subject from the Started record.
fn extract_subject(
  result: Result(actor.Started(Subject(Message)), actor.StartError),
) -> Result(Subject(Message), actor.StartError) {
  case result {
    Ok(started) -> Ok(started.data)
    Error(e) -> Error(e)
  }
}

/// Read env vars and pre-register a tenant if both are set.
fn init_from_env() -> Dict(String, TenantData) {
  case get_env("LEVEE_TENANT_ID"), get_env("LEVEE_TENANT_KEY") {
    Ok(tenant_id), Ok(tenant_key) -> {
      let data =
        TenantData(
          name: tenant_id,
          secret1: tenant_key,
          secret2: generate_secret(),
        )
      dict.from_list([#(tenant_id, data)])
    }
    _, _ -> dict.new()
  }
}
