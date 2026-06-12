import envoy
import gleam/bit_array
import gleam/crypto
import gleam/dynamic/decode
import gleam/http/request
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import wisp

pub const scope_doc_read = "doc:read"

pub const scope_doc_write = "doc:write"

pub const scope_summary_write = "summary:write"

pub type Secrets {
  Secrets(secret1: String, secret2: String)
}

pub type Claims {
  Claims(tenant_id: String, document_id: String, scopes: List(String), exp: Int)
}

pub type AuthError {
  MissingToken
  InvalidAuthHeader
  InvalidSignature
  TokenExpired
  InvalidTokenFormat
  UnknownTenant
  MissingTenantId
  TenantMismatch(token_tenant: String, request_tenant: String)
  DocumentMismatch(token_document: String, request_document: String)
  MissingScopes(scopes: List(String))
  AuthenticationError
}

type Header {
  Header(alg: String)
}

type JwtPayload {
  JwtPayload(
    tenant_id: String,
    document_id: String,
    scopes: List(String),
    exp: Int,
  )
}

@external(erlang, "levee_server_ffi", "put_tenant_secret")
fn ffi_put_tenant_secret(tenant_id: String, secret: String) -> Nil

@external(erlang, "levee_server_ffi", "get_tenant_secrets")
fn ffi_get_tenant_secrets(tenant_id: String) -> Result(#(String, String), Nil)

@external(erlang, "levee_server_ffi", "now_seconds")
fn now_unix() -> Int

pub fn put_secret_for_test(tenant_id: String, secret: String) -> Nil {
  ffi_put_tenant_secret(tenant_id, secret)
}

pub fn verify_request(
  req: wisp.Request,
  tenant_id: String,
  document_id: Option(String),
  required_scopes: List(String),
) -> Result(Claims, AuthError) {
  use token <- result.try(extract_token(req))
  use secrets <- result.try(runtime_secrets(tenant_id))
  use claims <- result.try(verify_token(token, tenant_id, secrets))
  use _ <- result.try(validate_document(claims, document_id))
  use _ <- result.try(require_scopes(claims, required_scopes))
  Ok(claims)
}

pub fn extract_token(req: wisp.Request) -> Result(String, AuthError) {
  case request.get_header(req, "authorization") {
    Error(Nil) -> Error(MissingToken)
    Ok(header) ->
      case header {
        "Bearer " <> token -> Ok(string.trim(token))
        _ -> Error(InvalidAuthHeader)
      }
  }
}

pub fn verify_token(
  token: String,
  request_tenant: String,
  secrets: Secrets,
) -> Result(Claims, AuthError) {
  case verify_with_secret(token, secrets.secret1) {
    Ok(claims) -> validate_tenant(claims, request_tenant)
    Error(InvalidSignature) ->
      case verify_with_secret(token, secrets.secret2) {
        Ok(claims) -> validate_tenant(claims, request_tenant)
        Error(error) -> Error(error)
      }
    Error(error) -> Error(error)
  }
}

pub fn require_scopes(
  claims: Claims,
  required_scopes: List(String),
) -> Result(Nil, AuthError) {
  let missing =
    required_scopes
    |> list.filter(fn(scope) { !list.contains(claims.scopes, scope) })

  case missing {
    [] -> Ok(Nil)
    _ -> Error(MissingScopes(missing))
  }
}

pub fn error_response(error: AuthError) -> wisp.Response {
  let #(status, message) = case error {
    MissingToken -> #(401, "Missing Authorization header")
    InvalidAuthHeader -> #(
      401,
      "Invalid Authorization header format. Expected: Bearer <token>",
    )
    InvalidSignature -> #(401, "Invalid token signature")
    TokenExpired -> #(401, "Token has expired")
    InvalidTokenFormat -> #(401, "Invalid token format")
    UnknownTenant -> #(401, "Unknown tenant")
    MissingTenantId -> #(400, "Missing tenant ID in request")
    TenantMismatch(_, _) -> #(403, "Token not valid for this tenant")
    DocumentMismatch(_, _) -> #(403, "Token not valid for this document")
    MissingScopes(scopes) -> #(
      403,
      "Missing required scopes: " <> string.join(scopes, ", "),
    )
    AuthenticationError -> #(500, "Authentication error")
  }

  json.object([#("error", json.string(message))])
  |> json.to_string
  |> wisp.json_response(status)
}

pub fn sign_for_test(
  tenant_id: String,
  document_id: String,
  user_id: String,
  scopes: List(String),
  secret: String,
  expires_in: Int,
) -> String {
  let now = now_unix()
  let payload =
    json.object([
      #("documentId", json.string(document_id)),
      #("scopes", json.array(scopes, json.string)),
      #("tenantId", json.string(tenant_id)),
      #("user", json.object([#("id", json.string(user_id))])),
      #("iat", json.int(now)),
      #("exp", json.int(now + expires_in)),
      #("ver", json.string("1.0")),
    ])
  sign_payload(payload, secret)
}

fn runtime_secrets(tenant_id: String) -> Result(Secrets, AuthError) {
  case ffi_get_tenant_secrets(tenant_id) {
    Ok(#(secret1, secret2)) -> Ok(Secrets(secret1, secret2))
    Error(Nil) ->
      case envoy.get("LEVEE_TENANT_ID"), envoy.get("LEVEE_TENANT_KEY") {
        Ok(id), Ok(secret) if id == tenant_id -> Ok(Secrets(secret, secret))
        _, _ -> Error(UnknownTenant)
      }
  }
}

fn validate_tenant(
  claims: Claims,
  request_tenant: String,
) -> Result(Claims, AuthError) {
  case claims.tenant_id == request_tenant {
    True -> Ok(claims)
    False -> Error(TenantMismatch(claims.tenant_id, request_tenant))
  }
}

fn validate_document(
  claims: Claims,
  document_id: Option(String),
) -> Result(Nil, AuthError) {
  case document_id {
    None -> Ok(Nil)
    Some(id) ->
      case claims.document_id == id {
        True -> Ok(Nil)
        False -> Error(DocumentMismatch(claims.document_id, id))
      }
  }
}

fn verify_with_secret(
  token: String,
  secret: String,
) -> Result(Claims, AuthError) {
  case string.split(token, ".") {
    [header_b64, payload_b64, signature_b64] -> {
      use header_json <- result.try(
        base64url_decode_to_string(header_b64)
        |> result.replace_error(InvalidTokenFormat),
      )
      use header <- result.try(
        json.parse(header_json, header_decoder())
        |> result.replace_error(InvalidTokenFormat),
      )

      case header.alg {
        "HS256" ->
          verify_signature_and_payload(
            header_b64,
            payload_b64,
            signature_b64,
            secret,
          )
        _ -> Error(InvalidTokenFormat)
      }
    }
    _ -> Error(InvalidTokenFormat)
  }
}

fn verify_signature_and_payload(
  header_b64: String,
  payload_b64: String,
  signature_b64: String,
  secret: String,
) -> Result(Claims, AuthError) {
  let message = header_b64 <> "." <> payload_b64
  let expected = sign_message(message, secret)
  case crypto.secure_compare(<<signature_b64:utf8>>, <<expected:utf8>>) {
    False -> Error(InvalidSignature)
    True -> {
      use payload_json <- result.try(
        base64url_decode_to_string(payload_b64)
        |> result.replace_error(InvalidTokenFormat),
      )
      use payload <- result.try(
        json.parse(payload_json, payload_decoder())
        |> result.replace_error(InvalidTokenFormat),
      )
      case payload.exp < now_unix() {
        True -> Error(TokenExpired)
        False ->
          Ok(Claims(
            tenant_id: payload.tenant_id,
            document_id: payload.document_id,
            scopes: payload.scopes,
            exp: payload.exp,
          ))
      }
    }
  }
}

fn header_decoder() -> decode.Decoder(Header) {
  use alg <- decode.field("alg", decode.string)
  decode.success(Header(alg:))
}

fn payload_decoder() -> decode.Decoder(JwtPayload) {
  use tenant_id <- decode.field("tenantId", decode.string)
  use document_id <- decode.field("documentId", decode.string)
  use scopes <- decode.field("scopes", decode.list(decode.string))
  use exp <- decode.field("exp", decode.int)
  decode.success(JwtPayload(tenant_id:, document_id:, scopes:, exp:))
}

fn sign_payload(payload: json.Json, secret: String) -> String {
  let header =
    json.object([#("alg", json.string("HS256")), #("typ", json.string("JWT"))])
  let header_b64 = base64url_encode_string(json.to_string(header))
  let payload_b64 = base64url_encode_string(json.to_string(payload))
  let message = header_b64 <> "." <> payload_b64
  message <> "." <> sign_message(message, secret)
}

fn sign_message(message: String, secret: String) -> String {
  crypto.hmac(<<message:utf8>>, crypto.Sha256, <<secret:utf8>>)
  |> bit_array.base64_url_encode(False)
}

fn base64url_encode_string(value: String) -> String {
  bit_array.from_string(value)
  |> bit_array.base64_url_encode(False)
}

fn base64url_decode_to_string(value: String) -> Result(String, Nil) {
  let padded = case string.length(value) % 4 {
    2 -> value <> "=="
    3 -> value <> "="
    _ -> value
  }
  use bits <- result.try(bit_array.base64_url_decode(padded))
  bit_array.to_string(bits)
}
