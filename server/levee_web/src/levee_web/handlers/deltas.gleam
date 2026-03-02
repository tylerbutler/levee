//// Delta (operation history) handler.
////
//// Ported from LeveeWeb.DeltaController (Elixir).

import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import levee_storage
import levee_storage/types
import levee_web/context.{type AuthenticatedContext}
import levee_web/json_helpers
import wisp.{type Request, type Response}

/// Maximum operations returned per request.
const max_ops_per_request = 2000

/// GET /deltas/:tenant_id/:id — get sequenced operations for a document.
///
/// Query parameters:
///   - from: Exclusive lower bound on sequence number (default -1)
///   - to: Exclusive upper bound on sequence number (default none)
pub fn index(
  req: Request,
  auth_ctx: AuthenticatedContext,
  document_id: String,
) -> Response {
  let tenant_id = auth_ctx.tenant_id
  let query_params = wisp.get_query(req)

  let from_sn = parse_int_param(query_params, "from", -1)
  let to_sn = parse_optional_int_param(query_params, "to")

  case auth_ctx.ctx.storage {
    None ->
      json_helpers.error_response(
        503,
        "service_unavailable",
        "Storage not configured",
      )

    Some(tables) ->
      case
        levee_storage.ets_get_deltas(
          tables,
          tenant_id,
          document_id,
          from_sn,
          to_sn,
          max_ops_per_request,
        )
      {
        Ok(deltas) -> {
          let messages = json.array(deltas, format_sequenced_message)
          json_helpers.json_response(200, messages)
        }

        Error(_) ->
          json_helpers.error_response(
            500,
            "server_error",
            "Failed to get deltas",
          )
      }
  }
}

// ---------------------------------------------------------------------------
// Private helpers
// ---------------------------------------------------------------------------

/// Parse an integer query parameter with a default value.
fn parse_int_param(
  params: List(#(String, String)),
  key: String,
  default: Int,
) -> Int {
  case list.key_find(params, key) {
    Ok(value) ->
      case int.parse(value) {
        Ok(n) -> n
        Error(_) -> default
      }
    Error(_) -> default
  }
}

/// Parse an optional integer query parameter (returns None if absent).
fn parse_optional_int_param(
  params: List(#(String, String)),
  key: String,
) -> Option(Int) {
  case list.key_find(params, key) {
    Ok(value) ->
      case int.parse(value) {
        Ok(n) -> Some(n)
        Error(_) -> None
      }
    Error(_) -> None
  }
}

/// Format a Delta as an ISequencedDocumentMessage JSON object.
fn format_sequenced_message(delta: types.Delta) -> json.Json {
  json.object([
    #("sequenceNumber", json.int(delta.sequence_number)),
    #("clientSequenceNumber", json.int(delta.client_sequence_number)),
    #("minimumSequenceNumber", json.int(delta.minimum_sequence_number)),
    #("clientId", json.nullable(delta.client_id, json.string)),
    #("referenceSequenceNumber", json.int(delta.reference_sequence_number)),
    #("type", json.string(delta.op_type)),
    // contents and metadata are Dynamic — encode as raw JSON
    #("contents", dynamic_to_json(delta.contents)),
    #("metadata", dynamic_to_json(delta.metadata)),
    #("timestamp", json.int(delta.timestamp)),
  ])
}

/// Convert a Dynamic value to a JSON value.
/// Falls back to null if the value cannot be represented.
@external(erlang, "levee_web_ffi", "dynamic_to_json")
fn dynamic_to_json(value: a) -> json.Json
