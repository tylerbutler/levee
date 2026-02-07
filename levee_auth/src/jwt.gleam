//// Minimal JWT implementation using HMAC-SHA256.
////
//// Implements HS256 signed JWTs without external dependencies.

import gleam/bit_array
import gleam/crypto
import gleam/dynamic/decode
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// JWT parsing/verification errors.
pub type JwtError {
  InvalidFormat
  InvalidBase64
  InvalidJson
  InvalidSignature
  MissingClaim(String)
}

/// Decoded JWT payload with common claims.
pub type JwtPayload {
  JwtPayload(
    sub: Option(String),
    iss: Option(String),
    iat: Option(Int),
    exp: Option(Int),
    jti: Option(String),
    tenant_id: Option(String),
    document_id: Option(String),
    scopes: Option(String),
  )
}

/// Create a signed JWT token.
///
/// Takes a payload as a JSON value and a secret key.
/// Returns a signed JWT string in the format: header.payload.signature
pub fn sign(payload: json.Json, secret: String) -> String {
  let header =
    json.object([#("alg", json.string("HS256")), #("typ", json.string("JWT"))])

  let header_b64 = header |> json.to_string |> base64url_encode
  let payload_b64 = payload |> json.to_string |> base64url_encode
  let message = header_b64 <> "." <> payload_b64

  let signature =
    crypto.hmac(<<message:utf8>>, crypto.Sha256, <<secret:utf8>>)
    |> base64url_encode_bits

  message <> "." <> signature
}

/// Verify a JWT token and extract the payload.
///
/// Returns the decoded payload with common JWT claims.
pub fn verify(token: String, secret: String) -> Result(JwtPayload, JwtError) {
  case string.split(token, ".") {
    [header_b64, payload_b64, signature_b64] -> {
      // Verify signature
      let message = header_b64 <> "." <> payload_b64
      let expected_sig =
        crypto.hmac(<<message:utf8>>, crypto.Sha256, <<secret:utf8>>)
        |> base64url_encode_bits

      case signature_b64 == expected_sig {
        False -> Error(InvalidSignature)
        True -> {
          // Decode payload
          use payload_json <- result.try(
            base64url_decode(payload_b64)
            |> result.replace_error(InvalidBase64),
          )
          use payload <- result.try(
            json.parse(payload_json, payload_decoder())
            |> result.replace_error(InvalidJson),
          )
          Ok(payload)
        }
      }
    }
    _ -> Error(InvalidFormat)
  }
}

/// Get a required string claim from payload.
pub fn get_string(payload: JwtPayload, key: String) -> Result(String, JwtError) {
  let value = case key {
    "sub" -> payload.sub
    "iss" -> payload.iss
    "jti" -> payload.jti
    "tenant_id" -> payload.tenant_id
    "document_id" -> payload.document_id
    "scopes" -> payload.scopes
    _ -> None
  }
  case value {
    Some(v) -> Ok(v)
    None -> Error(MissingClaim(key))
  }
}

/// Get a required int claim from payload.
pub fn get_int(payload: JwtPayload, key: String) -> Result(Int, JwtError) {
  let value = case key {
    "iat" -> payload.iat
    "exp" -> payload.exp
    _ -> None
  }
  case value {
    Some(v) -> Ok(v)
    None -> Error(MissingClaim(key))
  }
}

/// Get an optional string claim from payload.
pub fn get_optional_string(
  payload: JwtPayload,
  key: String,
) -> Result(String, Nil) {
  case get_string(payload, key) {
    Ok(v) -> Ok(v)
    Error(_) -> Error(Nil)
  }
}

// Decoder for JWT payload
fn payload_decoder() -> decode.Decoder(JwtPayload) {
  use sub <- decode.optional_field("sub", None, decode.optional(decode.string))
  use iss <- decode.optional_field("iss", None, decode.optional(decode.string))
  use iat <- decode.optional_field("iat", None, decode.optional(decode.int))
  use exp <- decode.optional_field("exp", None, decode.optional(decode.int))
  use jti <- decode.optional_field("jti", None, decode.optional(decode.string))
  use tenant_id <- decode.optional_field(
    "tenant_id",
    None,
    decode.optional(decode.string),
  )
  use document_id <- decode.optional_field(
    "document_id",
    None,
    decode.optional(decode.string),
  )
  use scopes <- decode.optional_field(
    "scopes",
    None,
    decode.optional(decode.string),
  )
  decode.success(JwtPayload(
    sub: sub,
    iss: iss,
    iat: iat,
    exp: exp,
    jti: jti,
    tenant_id: tenant_id,
    document_id: document_id,
    scopes: scopes,
  ))
}

// Base64URL encoding (RFC 4648)

fn base64url_encode(input: String) -> String {
  base64url_encode_bits(<<input:utf8>>)
}

fn base64url_encode_bits(input: BitArray) -> String {
  input
  |> bit_array.base64_encode(True)
  |> string.replace("+", "-")
  |> string.replace("/", "_")
  |> string.replace("=", "")
}

fn base64url_decode(input: String) -> Result(String, Nil) {
  // Add padding back
  let padded = case string.length(input) % 4 {
    2 -> input <> "=="
    3 -> input <> "="
    _ -> input
  }

  // Convert URL-safe chars back to standard base64
  let standard =
    padded
    |> string.replace("-", "+")
    |> string.replace("_", "/")

  case bit_array.base64_decode(standard) {
    Ok(bits) -> bit_array.to_string(bits)
    Error(_) -> Error(Nil)
  }
}
