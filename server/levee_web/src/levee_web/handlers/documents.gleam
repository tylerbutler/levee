//// Document handlers — create, get metadata, get session info.
////
//// Ported from LeveeWeb.DocumentController (Elixir).

import gleam/dynamic/decode
import gleam/http/request
import gleam/json
import gleam/option.{None, Some}
import levee_storage
import levee_storage/types
import levee_web/context.{type AuthenticatedContext}
import levee_web/json_helpers
import wisp.{type Request, type Response}

/// POST /documents/:tenant_id — create a new document.
///
/// Request body (JSON):
///   - id (optional): Document ID, auto-generated if omitted
///   - sequenceNumber (optional): Initial sequence number (default 0)
///   - summary (optional): Initial summary tree
///   - enableDiscovery (optional): If true, return session info alongside ID
pub fn create(req: Request, auth_ctx: AuthenticatedContext) -> Response {
  use body <- wisp.require_json(req)

  // Decode optional fields from the JSON body
  let body_result =
    decode.run(body, {
      use id <- decode.optional_field(
        "id",
        None,
        decode.optional(decode.string),
      )
      use sequence_number <- decode.optional_field(
        "sequenceNumber",
        0,
        decode.int,
      )
      use enable_discovery <- decode.optional_field(
        "enableDiscovery",
        False,
        decode.bool,
      )
      decode.success(#(id, sequence_number, enable_discovery))
    })

  case body_result {
    Error(_) ->
      json_helpers.error_response(400, "bad_request", "Invalid request body")

    Ok(#(maybe_id, sequence_number, enable_discovery)) -> {
      let document_id = case maybe_id {
        Some(id) -> id
        None -> generate_document_id()
      }
      let tenant_id = auth_ctx.tenant_id

      case auth_ctx.ctx.storage {
        None ->
          json_helpers.error_response(
            503,
            "service_unavailable",
            "Storage not configured",
          )

        Some(tables) ->
          case
            levee_storage.ets_create_document(
              tables,
              tenant_id,
              document_id,
              sequence_number,
            )
          {
            Ok(_document) -> {
              // TODO: process summary tree when wired up
              case enable_discovery {
                True ->
                  json_helpers.json_response(
                    201,
                    json.object([
                      #("id", json.string(document_id)),
                      #(
                        "session",
                        session_info_json(req, tenant_id, document_id),
                      ),
                    ]),
                  )
                False ->
                  json_helpers.json_response(201, json.string(document_id))
              }
            }

            Error(types.AlreadyExists) ->
              json_helpers.error_response(
                409,
                "conflict",
                "Document already exists",
              )

            Error(_) ->
              json_helpers.error_response(
                400,
                "bad_request",
                "Failed to create document",
              )
          }
      }
    }
  }
}

/// GET /documents/:tenant_id/:id — get document metadata.
pub fn show(
  _req: Request,
  auth_ctx: AuthenticatedContext,
  document_id: String,
) -> Response {
  let tenant_id = auth_ctx.tenant_id

  case auth_ctx.ctx.storage {
    None ->
      json_helpers.error_response(
        503,
        "service_unavailable",
        "Storage not configured",
      )

    Some(tables) ->
      case levee_storage.ets_get_document(tables, tenant_id, document_id) {
        Ok(document) ->
          json_helpers.json_response(
            200,
            json.object([
              #("id", json.string(document.id)),
              #("tenantId", json.string(document.tenant_id)),
              #("sequenceNumber", json.int(document.sequence_number)),
            ]),
          )

        Error(types.NotFound) ->
          json_helpers.error_response(404, "not_found", "Document not found")

        Error(_) ->
          json_helpers.error_response(
            500,
            "server_error",
            "Failed to get document",
          )
      }
  }
}

/// GET /documents/:tenant_id/session/:id — get session info for a document.
pub fn session(
  req: Request,
  auth_ctx: AuthenticatedContext,
  document_id: String,
) -> Response {
  let tenant_id = auth_ctx.tenant_id

  case auth_ctx.ctx.storage {
    None ->
      json_helpers.error_response(
        503,
        "service_unavailable",
        "Storage not configured",
      )

    Some(tables) ->
      case levee_storage.ets_get_document(tables, tenant_id, document_id) {
        Ok(_document) ->
          json_helpers.json_response(
            200,
            session_info_json(req, tenant_id, document_id),
          )

        Error(types.NotFound) ->
          json_helpers.error_response(404, "not_found", "Document not found")

        Error(_) ->
          json_helpers.error_response(
            500,
            "server_error",
            "Failed to get document",
          )
      }
  }
}

// ---------------------------------------------------------------------------
// Private helpers
// ---------------------------------------------------------------------------

/// Generate a random 16-byte hex document ID.
fn generate_document_id() -> String {
  random_hex_bytes(16)
}

/// Build session info as a JSON object using the request's scheme and host.
fn session_info_json(
  req: Request,
  tenant_id: String,
  document_id: String,
) -> json.Json {
  let host = build_base_url(req)

  // TODO: check if session GenServer is alive once registry is wired up
  let is_alive = False

  json.object([
    #("ordererUrl", json.string(host <> "/socket")),
    #("historianUrl", json.string(host <> "/repos/" <> tenant_id)),
    #(
      "deltaStreamUrl",
      json.string(host <> "/deltas/" <> tenant_id <> "/" <> document_id),
    ),
    #("isSessionAlive", json.bool(is_alive)),
    #("isSessionActive", json.bool(is_alive)),
  ])
}

/// Reconstruct the base URL from the request's scheme and host header.
fn build_base_url(req: Request) -> String {
  let scheme = case request.get_header(req, "x-forwarded-proto") {
    Ok(proto) -> proto
    Error(_) -> "http"
  }
  let host = case request.get_header(req, "host") {
    Ok(h) -> h
    Error(_) -> "localhost:4000"
  }
  scheme <> "://" <> host
}

/// Generate `n` random bytes and return as lowercase hex.
@external(erlang, "levee_web_ffi", "random_hex_bytes")
fn random_hex_bytes(n: Int) -> String
