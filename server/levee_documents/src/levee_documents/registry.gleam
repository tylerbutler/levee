//// Registry actor keyed by `{tenant_id, document_id}`.
////
//// It mirrors the Elixir Registry wrapper: lookups are stateful, and misses are
//// started through the session factory supervisor.

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import gleam/otp/factory_supervisor as factory
import levee_documents/session
import levee_storage

pub type Message {
  GetOrCreate(
    String,
    String,
    Subject(Result(Subject(session.Message), RegistryError)),
  )
  Get(String, String, Subject(Result(Subject(session.Message), RegistryError)))
  Register(String, String, Subject(session.Message))
  Shutdown(Subject(Nil))
}

pub type RegistryError {
  NotFound
  StartFailed(String)
}

type State {
  State(
    tables: levee_storage.Tables,
    factory: factory.Supervisor(session.StartArgs, Subject(session.Message)),
    sessions: Dict(String, Subject(session.Message)),
  )
}

pub fn start(
  tables: levee_storage.Tables,
  supervisor: factory.Supervisor(session.StartArgs, Subject(session.Message)),
) -> actor.StartResult(Subject(Message)) {
  actor.new(State(tables: tables, factory: supervisor, sessions: dict.new()))
  |> actor.on_message(handle_message)
  |> actor.start
  |> extract_subject
}

pub fn get_or_create_session(
  registry: Subject(Message),
  tenant_id: String,
  document_id: String,
) -> Result(Subject(session.Message), RegistryError) {
  process.call(registry, 5000, fn(reply) {
    GetOrCreate(tenant_id, document_id, reply)
  })
}

pub fn get_session(
  registry: Subject(Message),
  tenant_id: String,
  document_id: String,
) -> Result(Subject(session.Message), RegistryError) {
  process.call(registry, 5000, fn(reply) { Get(tenant_id, document_id, reply) })
}

fn handle_message(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    GetOrCreate(tenant_id, document_id, reply_to) -> {
      let key = make_key(tenant_id, document_id)
      case dict.get(state.sessions, key) {
        Ok(actor) -> {
          process.send(reply_to, Ok(actor))
          actor.continue(state)
        }
        Error(_) -> {
          let args =
            session.StartArgs(
              tables: state.tables,
              tenant_id: tenant_id,
              document_id: document_id,
            )
          case factory.start_child(state.factory, args) {
            Ok(started) -> {
              let sessions = dict.insert(state.sessions, key, started.data)
              process.send(reply_to, Ok(started.data))
              actor.continue(State(..state, sessions: sessions))
            }
            Error(_reason) -> {
              process.send(reply_to, Error(StartFailed("session start failed")))
              actor.continue(state)
            }
          }
        }
      }
    }

    Get(tenant_id, document_id, reply_to) -> {
      case dict.get(state.sessions, make_key(tenant_id, document_id)) {
        Ok(actor) -> process.send(reply_to, Ok(actor))
        Error(_) -> process.send(reply_to, Error(NotFound))
      }
      actor.continue(state)
    }

    Register(tenant_id, document_id, session_actor) -> {
      let sessions =
        dict.insert(
          state.sessions,
          make_key(tenant_id, document_id),
          session_actor,
        )
      actor.continue(State(..state, sessions: sessions))
    }

    Shutdown(reply_to) -> {
      process.send(reply_to, Nil)
      actor.stop()
    }
  }
}

fn make_key(tenant_id: String, document_id: String) -> String {
  tenant_id <> "\u{0}" <> document_id
}

fn extract_subject(
  result: Result(actor.Started(Subject(Message)), actor.StartError),
) -> Result(actor.Started(Subject(Message)), actor.StartError) {
  result
}
