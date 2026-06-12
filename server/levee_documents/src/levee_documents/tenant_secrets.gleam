//// Pure-Gleam tenant secrets actor.
////
//// This mirrors the Elixir-facing API of `Levee.Auth.TenantSecrets` while
//// avoiding the old unique-names FFI. Generated tenant IDs are deterministic
//// from tenant count plus a random suffix; explicit registration is preserved.

import gleam/bit_array
import gleam/crypto
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/otp/actor
import gleam/string

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

pub type Message {
  CreateTenant(String, Subject(Result(TenantWithSecrets, TenantSecretsError)))
  GetTenant(String, Subject(Result(TenantInfo, TenantSecretsError)))
  GetSecrets(String, Subject(Result(#(String, String), TenantSecretsError)))
  GetSecret(String, Subject(Result(String, TenantSecretsError)))
  RegenerateSecret(
    String,
    SecretSlot,
    Subject(Result(String, TenantSecretsError)),
  )
  RegisterTenant(String, String, Subject(Nil))
  UnregisterTenant(String, Subject(Nil))
  TenantExists(String, Subject(Bool))
  ListTenants(Subject(List(String)))
  ListTenantsWithNames(Subject(List(TenantInfo)))
  Shutdown(Subject(Nil))
}

type State {
  State(tenants: Dict(String, TenantData))
}

pub fn start() -> Result(Subject(Message), actor.StartError) {
  actor.new(State(tenants: dict.new()))
  |> actor.on_message(handle_message)
  |> actor.start
  |> extract_subject
}

pub fn create_tenant(
  actor: Subject(Message),
  name: String,
) -> Result(TenantWithSecrets, TenantSecretsError) {
  process.call(actor, 5000, fn(reply) { CreateTenant(name, reply) })
}

pub fn get_tenant(
  actor: Subject(Message),
  id: String,
) -> Result(TenantInfo, TenantSecretsError) {
  process.call(actor, 5000, fn(reply) { GetTenant(id, reply) })
}

pub fn get_secrets(
  actor: Subject(Message),
  id: String,
) -> Result(#(String, String), TenantSecretsError) {
  process.call(actor, 5000, fn(reply) { GetSecrets(id, reply) })
}

pub fn get_secret(
  actor: Subject(Message),
  id: String,
) -> Result(String, TenantSecretsError) {
  process.call(actor, 5000, fn(reply) { GetSecret(id, reply) })
}

pub fn regenerate_secret(
  actor: Subject(Message),
  id: String,
  slot: SecretSlot,
) -> Result(String, TenantSecretsError) {
  process.call(actor, 5000, fn(reply) { RegenerateSecret(id, slot, reply) })
}

pub fn register_tenant(
  actor: Subject(Message),
  id: String,
  secret: String,
) -> Nil {
  process.call(actor, 5000, fn(reply) { RegisterTenant(id, secret, reply) })
}

pub fn unregister_tenant(actor: Subject(Message), id: String) -> Nil {
  process.call(actor, 5000, fn(reply) { UnregisterTenant(id, reply) })
}

pub fn tenant_exists(actor: Subject(Message), id: String) -> Bool {
  process.call(actor, 5000, fn(reply) { TenantExists(id, reply) })
}

pub fn list_tenants(actor: Subject(Message)) -> List(String) {
  process.call(actor, 5000, fn(reply) { ListTenants(reply) })
}

pub fn list_tenants_with_names(actor: Subject(Message)) -> List(TenantInfo) {
  process.call(actor, 5000, fn(reply) { ListTenantsWithNames(reply) })
}

pub fn generate_secret() -> String {
  crypto.strong_random_bytes(32)
  |> bit_array.base16_encode
  |> string.lowercase
}

fn handle_message(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    CreateTenant(name, reply_to) -> {
      let id = generate_tenant_id(name, state.tenants)
      let secret1 = generate_secret()
      let secret2 = generate_secret()
      let tenants =
        dict.insert(
          state.tenants,
          id,
          TenantData(name: name, secret1: secret1, secret2: secret2),
        )
      process.send(
        reply_to,
        Ok(TenantWithSecrets(
          id: id,
          name: name,
          secret1: secret1,
          secret2: secret2,
        )),
      )
      actor.continue(State(tenants: tenants))
    }
    GetTenant(id, reply_to) -> {
      process.send(reply_to, case dict.get(state.tenants, id) {
        Ok(data) -> Ok(TenantInfo(id: id, name: data.name))
        Error(_) -> Error(TenantNotFound)
      })
      actor.continue(state)
    }
    GetSecrets(id, reply_to) -> {
      process.send(reply_to, case dict.get(state.tenants, id) {
        Ok(data) -> Ok(#(data.secret1, data.secret2))
        Error(_) -> Error(TenantNotFound)
      })
      actor.continue(state)
    }
    GetSecret(id, reply_to) -> {
      process.send(reply_to, case dict.get(state.tenants, id) {
        Ok(data) -> Ok(data.secret1)
        Error(_) -> Error(TenantNotFound)
      })
      actor.continue(state)
    }
    RegenerateSecret(id, slot, reply_to) -> {
      case dict.get(state.tenants, id) {
        Error(_) -> {
          process.send(reply_to, Error(TenantNotFound))
          actor.continue(state)
        }
        Ok(data) -> {
          let secret = generate_secret()
          let data = case slot {
            Slot1 -> TenantData(..data, secret1: secret)
            Slot2 -> TenantData(..data, secret2: secret)
          }
          process.send(reply_to, Ok(secret))
          actor.continue(State(tenants: dict.insert(state.tenants, id, data)))
        }
      }
    }
    RegisterTenant(id, secret, reply_to) -> {
      let tenants =
        dict.insert(
          state.tenants,
          id,
          TenantData(name: id, secret1: secret, secret2: generate_secret()),
        )
      process.send(reply_to, Nil)
      actor.continue(State(tenants: tenants))
    }
    UnregisterTenant(id, reply_to) -> {
      process.send(reply_to, Nil)
      actor.continue(State(tenants: dict.delete(state.tenants, id)))
    }
    TenantExists(id, reply_to) -> {
      process.send(reply_to, dict.has_key(state.tenants, id))
      actor.continue(state)
    }
    ListTenants(reply_to) -> {
      process.send(reply_to, dict.keys(state.tenants))
      actor.continue(state)
    }
    ListTenantsWithNames(reply_to) -> {
      let tenants =
        state.tenants
        |> dict.to_list
        |> list.map(fn(entry) {
          let #(id, data) = entry
          TenantInfo(id: id, name: data.name)
        })
      process.send(reply_to, tenants)
      actor.continue(state)
    }
    Shutdown(reply_to) -> {
      process.send(reply_to, Nil)
      actor.stop()
    }
  }
}

fn generate_tenant_id(name: String, tenants: Dict(String, TenantData)) -> String {
  let suffix =
    crypto.strong_random_bytes(3) |> bit_array.base16_encode |> string.lowercase
  let count = dict.size(tenants) + 1
  let base = case string.trim(name) {
    "" -> "tenant"
    value -> value |> string.lowercase |> string.replace(" ", "-")
  }
  base <> "-" <> int.to_string(count) <> "-" <> suffix
}

fn extract_subject(
  result: Result(actor.Started(Subject(Message)), actor.StartError),
) -> Result(Subject(Message), actor.StartError) {
  case result {
    Ok(started) -> Ok(started.data)
    Error(error) -> Error(error)
  }
}
