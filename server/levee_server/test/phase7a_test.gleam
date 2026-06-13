import gleam/http
import gleam/http/request
import gleam/result
import gleeunit/should
import levee_documents/supervisor as documents_supervisor
import levee_documents/tenant_secrets
import levee_server
import levee_server/auth
import wisp/simulate

pub fn otp_tree_starts_and_creates_document_session_test() {
  let assert Ok(tree) =
    levee_server.start_otp_tree_for_test("build/phase7a-otp-tree-test")

  tenant_secrets.get_secrets(tree.tenant_secrets, "sandbag")
  |> should.be_ok

  documents_supervisor.get_or_create_session(
    tree.document_supervisor,
    "sandbag",
    "phase7a-doc",
  )
  |> should.be_ok

  documents_supervisor.get_session(
    tree.document_supervisor,
    "sandbag",
    "phase7a-doc",
  )
  |> result.map(fn(_) { Nil })
  |> should.equal(Ok(Nil))
}

pub fn unknown_tenant_read_route_is_handled_natively_test() {
  let _ = levee_server.start_otp_tree_for_test("build/phase7a-route-test")
  let token =
    auth.sign_for_test(
      "missing-tenant",
      "doc",
      "user",
      ["doc:read"],
      "not-registered",
      3600,
    )

  let response =
    simulate.request(http.Get, "/documents/missing-tenant/doc")
    |> request.set_header("authorization", "Bearer " <> token)
    |> levee_server.handle_request

  response.status
  |> should.equal(401)
  simulate.read_body(response)
  |> should.equal("{\"error\":\"Unknown tenant\"}")
}
