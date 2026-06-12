import gleam/dict
import gleam/dynamic
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import levee_documents/session
import levee_documents/supervisor
import levee_documents/tenant_secrets
import levee_storage

fn tables() {
  levee_storage.ets_init("build")
}

fn empty_client() {
  dynamic.nil()
}

fn op(csn: Int, rsn: Int, content: String) {
  session.Operation(
    client_sequence_number: csn,
    reference_sequence_number: rsn,
    message_type: "op",
    contents: dynamic.string(content),
    metadata: None,
  )
}

pub fn supervisor_starts_session_and_sequences_ops_test() {
  let tables = tables()
  let assert Ok(sup) = supervisor.start(tables)
  let assert Ok(actor) =
    supervisor.get_or_create_session(sup, "tenant-a", "doc-a")

  let assert Ok(joined) =
    session.client_join(
      actor,
      session.Connect(
        client: empty_client(),
        mode: session.Write,
        supported_features: dict.new(),
        versions: ["^1.0.0"],
      ),
    )

  let assert Ok(sequenced) =
    session.submit_ops(actor, joined.client_id, [op(1, 1, "hello")])
  list.length(sequenced) |> should.equal(1)
  let assert [first] = sequenced
  first.sequence_number |> should.equal(2)
  first.client_id |> should.equal(Some(joined.client_id))

  let assert Ok(summary) = session.get_state_summary(actor)
  summary.current_sn |> should.equal(2)
  summary.client_count |> should.equal(1)

  levee_storage.ets_close(tables)
}

pub fn registry_returns_same_actor_for_same_key_test() {
  let tables = tables()
  let assert Ok(sup) = supervisor.start(tables)
  let assert Ok(first) =
    supervisor.get_or_create_session(sup, "tenant-b", "doc-b")
  let assert Ok(second) =
    supervisor.get_or_create_session(sup, "tenant-b", "doc-b")
  process.subject_owner(first) |> should.equal(process.subject_owner(second))
  levee_storage.ets_close(tables)
}

pub fn broadcast_subscriber_receives_ops_test() {
  let tables = tables()
  let assert Ok(sup) = supervisor.start(tables)
  let assert Ok(actor) =
    supervisor.get_or_create_session(sup, "tenant-c", "doc-c")
  let assert Ok(joined) =
    session.client_join(
      actor,
      session.Connect(
        client: empty_client(),
        mode: session.Write,
        supported_features: dict.new(),
        versions: ["^0.1.0"],
      ),
    )
  let subscriber = process.new_subject()
  session.subscribe(actor, joined.client_id, subscriber)
  let assert Ok(_) =
    session.submit_ops(actor, joined.client_id, [op(1, 1, "broadcast")])
  let assert Ok(session.OpsBroadcast("doc-c", ops)) =
    process.receive(subscriber, 500)
  list.length(ops) |> should.equal(1)
  levee_storage.ets_close(tables)
}

pub fn tenant_secrets_register_and_lookup_test() {
  let assert Ok(actor) = tenant_secrets.start()
  tenant_secrets.register_tenant(actor, "tenant-secret", "secret-1")
  tenant_secrets.tenant_exists(actor, "tenant-secret") |> should.be_true
  tenant_secrets.get_secret(actor, "tenant-secret")
  |> should.equal(Ok("secret-1"))
  list.contains(tenant_secrets.list_tenants(actor), "tenant-secret")
  |> should.be_true
}
