//// Dynamic supervisor facade for document sessions.
////
//// A `gleam_otp` factory supervisor owns session actors; a registry actor
//// serializes get-or-create to preserve one session per `{tenant, document}`.

import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import gleam/otp/factory_supervisor as factory
import gleam/otp/supervision
import levee_documents/registry
import levee_documents/session
import levee_storage

pub type Supervisor {
  Supervisor(
    factory: factory.Supervisor(session.StartArgs, Subject(session.Message)),
    registry: Subject(registry.Message),
  )
}

pub type StartError {
  FactoryStartFailed(actor.StartError)
  RegistryStartFailed(actor.StartError)
}

pub fn start(tables: levee_storage.Tables) -> Result(Supervisor, StartError) {
  let factory_result =
    factory.worker_child(session.start)
    |> factory.restart_strategy(supervision.Transient)
    |> factory.start

  case factory_result {
    Error(error) -> Error(FactoryStartFailed(error))
    Ok(started_factory) -> {
      case registry.start(tables, started_factory.data) {
        Error(error) -> Error(RegistryStartFailed(error))
        Ok(started_registry) ->
          Ok(Supervisor(
            factory: started_factory.data,
            registry: started_registry.data,
          ))
      }
    }
  }
}

pub fn get_or_create_session(
  supervisor: Supervisor,
  tenant_id: String,
  document_id: String,
) -> Result(Subject(session.Message), registry.RegistryError) {
  registry.get_or_create_session(supervisor.registry, tenant_id, document_id)
}

pub fn get_session(
  supervisor: Supervisor,
  tenant_id: String,
  document_id: String,
) -> Result(Subject(session.Message), registry.RegistryError) {
  registry.get_session(supervisor.registry, tenant_id, document_id)
}
