import gleam/dynamic/decode
import gleam/http
import gleam/http/request
import gleam/json
import gleam/string
import gleeunit/should
import levee_server
import levee_server/auth
import levee_server/storage
import levee_storage
import wisp/simulate

const secret = "phase2-secret"

const user = "phase2-user"

pub fn create_blob_with_summary_scope_is_native_test() {
  let tenant = "phase2-blob-tenant"
  setup_storage()
  auth.put_secret_for_test(tenant, secret)
  let token =
    auth.sign_for_test(
      tenant,
      "doc",
      user,
      ["doc:read", "summary:write"],
      secret,
      3600,
    )

  let response =
    simulate.request(http.Post, "/repos/" <> tenant <> "/git/blobs")
    |> request.set_header("authorization", "Bearer " <> token)
    |> simulate.json_body(
      json.object([
        #("content", json.string("aGVsbG8=")),
        #("encoding", json.string("base64")),
      ]),
    )
    |> levee_server.handle_request

  let sha = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
  response.status
  |> should.equal(201)
  simulate.read_body(response)
  |> should.equal(
    "{\"sha\":\""
    <> sha
    <> "\",\"url\":\"https://wisp.example.com/repos/"
    <> tenant
    <> "/git/blobs/"
    <> sha
    <> "\"}",
  )
}

pub fn create_blob_without_summary_scope_is_forbidden_test() {
  let tenant = "phase2-forbidden-tenant"
  setup_storage()
  auth.put_secret_for_test(tenant, secret)
  let token =
    auth.sign_for_test(tenant, "doc", user, ["doc:read"], secret, 3600)

  let response =
    simulate.request(http.Post, "/repos/" <> tenant <> "/git/blobs")
    |> request.set_header("authorization", "Bearer " <> token)
    |> simulate.json_body(json.object([#("content", json.string("hello"))]))
    |> levee_server.handle_request

  response.status
  |> should.equal(403)
  simulate.read_body(response)
  |> should.equal("{\"error\":\"Missing required scopes: summary:write\"}")
}

pub fn register_then_login_returns_session_tokens_test() {
  let email = "phase2-login@example.com"

  let register_response =
    simulate.request(http.Post, "/api/auth/register")
    |> simulate.json_body(
      json.object([
        #("email", json.string(email)),
        #("password", json.string("secure_password_123")),
        #("display_name", json.string("Phase Two")),
      ]),
    )
    |> levee_server.handle_request

  register_response.status
  |> should.equal(201)
  let register_body =
    simulate.read_body(register_response)
    |> decode_auth_response
  let assert Ok(register_auth) = register_body
  register_auth.user.email
  |> should.equal(email)
  register_auth.user.display_name
  |> should.equal("Phase Two")
  string_starts_with(register_auth.token, "ses_")
  |> should.equal(True)

  let login_response =
    simulate.request(http.Post, "/api/auth/login")
    |> simulate.json_body(
      json.object([
        #("email", json.string(email)),
        #("password", json.string("secure_password_123")),
      ]),
    )
    |> levee_server.handle_request

  login_response.status
  |> should.equal(200)
  let assert Ok(login_auth) =
    simulate.read_body(login_response)
    |> decode_auth_response
  login_auth.user.id
  |> should.equal(register_auth.user.id)
  string_starts_with(login_auth.token, "ses_")
  |> should.equal(True)
}

pub fn token_mint_returns_document_jwt_for_session_member_test() {
  let tenant = "phase2-token-tenant"
  let email = "phase2-token@example.com"
  setup_storage()
  auth.put_secret_for_test(tenant, secret)

  let register_response =
    simulate.request(http.Post, "/api/auth/register")
    |> simulate.json_body(
      json.object([
        #("email", json.string(email)),
        #("password", json.string("secure_password_123")),
        #("display_name", json.string("Token User")),
      ]),
    )
    |> levee_server.handle_request
  let assert Ok(auth_response) =
    simulate.read_body(register_response)
    |> decode_auth_response

  let mint_response =
    simulate.request(http.Post, "/api/tenants/" <> tenant <> "/token-mint")
    |> request.set_header("authorization", "Bearer " <> auth_response.token)
    |> simulate.json_body(
      json.object([#("documentId", json.string("doc-123"))]),
    )
    |> levee_server.handle_request

  mint_response.status
  |> should.equal(200)
  let assert Ok(mint) =
    simulate.read_body(mint_response)
    |> decode_mint_response
  mint.expires_in
  |> should.equal(3600)
  mint.user.name
  |> should.equal("Token User")
  auth.verify_token(mint.jwt, tenant, auth.Secrets(secret, secret))
  |> should.be_ok
}

fn setup_storage() {
  case storage.get_tables() {
    Ok(_) -> Nil
    Error(Nil) -> {
      storage.ensure_dir_for_test("build/phase2-test-storage")
      let tables = levee_storage.ets_init("build/phase2-test-storage")
      storage.put_tables_for_test(tables)
    }
  }
}

type AuthResponse {
  AuthResponse(user: ResponseUser, token: String)
}

type ResponseUser {
  ResponseUser(
    id: String,
    email: String,
    display_name: String,
    is_admin: Bool,
    created_at: Int,
  )
}

type MintResponse {
  MintResponse(jwt: String, expires_in: Int, user: MintUser)
}

type MintUser {
  MintUser(id: String, name: String)
}

fn decode_auth_response(body: String) {
  json.parse(body, {
    use user <- decode.field("user", {
      use id <- decode.field("id", decode.string)
      use email <- decode.field("email", decode.string)
      use display_name <- decode.field("display_name", decode.string)
      use is_admin <- decode.field("is_admin", decode.bool)
      use created_at <- decode.field("created_at", decode.int)
      decode.success(ResponseUser(
        id:,
        email:,
        display_name:,
        is_admin:,
        created_at:,
      ))
    })
    use token <- decode.field("token", decode.string)
    decode.success(AuthResponse(user:, token:))
  })
}

fn decode_mint_response(body: String) {
  json.parse(body, {
    use jwt <- decode.field("jwt", decode.string)
    use expires_in <- decode.field("expiresIn", decode.int)
    use user <- decode.field("user", {
      use id <- decode.field("id", decode.string)
      use name <- decode.field("name", decode.string)
      decode.success(MintUser(id:, name:))
    })
    decode.success(MintResponse(jwt:, expires_in:, user:))
  })
}

fn string_starts_with(value: String, prefix: String) -> Bool {
  string.starts_with(value, prefix)
}
