//// JWT implementation using gwt (HS256).
////
//// Wraps the gwt library to provide Levee-specific JWT operations.

import gleam/dynamic/decode
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/result
import gwt

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
  // We need to extract values from the JSON to set them as gwt claims.
  // Since we receive a json.Json value, we encode it to string, then decode
  // the fields back out to set on the builder.
  let json_str = json.to_string(payload)
  let decoded =
    json.parse(json_str, payload_decoder())
    |> result.unwrap(JwtPayload(
      sub: None,
      iss: None,
      iat: None,
      exp: None,
      jti: None,
      tenant_id: None,
      document_id: None,
      scopes: None,
    ))

  let builder = gwt.new()

  // Set standard claims
  let builder = case decoded.sub {
    Some(v) -> gwt.set_subject(builder, v)
    None -> builder
  }
  let builder = case decoded.iss {
    Some(v) -> gwt.set_issuer(builder, v)
    None -> builder
  }
  let builder = case decoded.iat {
    Some(v) -> gwt.set_issued_at(builder, v)
    None -> builder
  }
  let builder = case decoded.exp {
    Some(v) -> gwt.set_expiration(builder, v)
    None -> builder
  }
  let builder = case decoded.jti {
    Some(v) -> gwt.set_jwt_id(builder, v)
    None -> builder
  }

  // Set custom claims
  let builder = case decoded.tenant_id {
    Some(v) -> gwt.set_payload_claim(builder, "tenant_id", json.string(v))
    None -> builder
  }
  let builder = case decoded.document_id {
    Some(v) -> gwt.set_payload_claim(builder, "document_id", json.string(v))
    None -> builder
  }
  let builder = case decoded.scopes {
    Some(v) -> gwt.set_payload_claim(builder, "scopes", json.string(v))
    None -> builder
  }

  gwt.to_signed_string(builder, gwt.HS256, secret)
}

/// Verify a JWT token and extract the payload.
///
/// Returns the decoded payload with common JWT claims.
pub fn verify(token: String, secret: String) -> Result(JwtPayload, JwtError) {
  case gwt.from_signed_string(token, secret) {
    Error(_) -> Error(InvalidSignature)
    Ok(jwt) -> {
      let sub = gwt.get_subject(from: jwt) |> option.from_result
      let iss = gwt.get_issuer(from: jwt) |> option.from_result
      let iat = gwt.get_issued_at(from: jwt) |> option.from_result
      let exp = gwt.get_expiration(from: jwt) |> option.from_result
      let jti = gwt.get_jwt_id(from: jwt) |> option.from_result
      let tenant_id =
        gwt.get_payload_claim(from: jwt, claim: "tenant_id", decoder: decode.string)
        |> option.from_result
      let document_id =
        gwt.get_payload_claim(from: jwt, claim: "document_id", decoder: decode.string)
        |> option.from_result
      let scopes =
        gwt.get_payload_claim(from: jwt, claim: "scopes", decoder: decode.string)
        |> option.from_result

      Ok(JwtPayload(
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

// Decoder for JWT payload (used internally by sign to extract fields from JSON)
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
