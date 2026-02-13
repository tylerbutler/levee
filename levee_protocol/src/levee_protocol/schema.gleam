/// JSON Schema generation for Levee protocol types
/// Builds JSON Schema (Draft 07) directly using gleam/json
import gleam/json.{type Json}

// ─────────────────────────────────────────────────────────────────────────────
// Schema helpers
// ─────────────────────────────────────────────────────────────────────────────

fn string_type() -> Json {
  json.object([#("type", json.string("string"))])
}

fn int_type() -> Json {
  json.object([#("type", json.string("integer"))])
}

fn bool_type() -> Json {
  json.object([#("type", json.string("boolean"))])
}

fn any_type() -> Json {
  json.bool(True)
}

fn nullable_string() -> Json {
  json.object([
    #(
      "type",
      json.preprocessed_array([json.string("string"), json.string("null")]),
    ),
  ])
}

fn string_array() -> Json {
  json.object([#("type", json.string("array")), #("items", string_type())])
}

fn array_of(items: Json) -> Json {
  json.object([#("type", json.string("array")), #("items", items)])
}

fn ref(name: String) -> Json {
  json.object([#("$ref", json.string("#/$defs/" <> name))])
}

fn string_enum(values: List(String)) -> Json {
  json.object([
    #("type", json.string("string")),
    #("enum", json.array(values, json.string)),
  ])
}

fn object_schema(
  properties: List(#(String, Json)),
  required: List(String),
) -> Json {
  json.object([
    #("type", json.string("object")),
    #("properties", json.object(properties)),
    #("required", json.array(required, json.string)),
    #("additionalProperties", json.bool(False)),
  ])
}

// ─────────────────────────────────────────────────────────────────────────────
// Type schemas
// ─────────────────────────────────────────────────────────────────────────────

fn connection_mode_schema() -> Json {
  string_enum(["write", "read"])
}

fn scope_schema() -> Json {
  string_enum(["doc:read", "doc:write", "summary:write"])
}

fn user_schema() -> Json {
  object_schema(
    [
      #("id", string_type()),
      #(
        "properties",
        json.object([
          #("type", json.string("object")),
          #("additionalProperties", any_type()),
        ]),
      ),
    ],
    ["id", "properties"],
  )
}

fn client_capabilities_schema() -> Json {
  object_schema([#("interactive", bool_type())], ["interactive"])
}

fn client_details_schema() -> Json {
  object_schema(
    [
      #("capabilities", ref("ClientCapabilities")),
      #("client_type", string_type()),
      #("environment", string_type()),
      #("device", string_type()),
    ],
    ["capabilities"],
  )
}

fn client_schema() -> Json {
  object_schema(
    [
      #("mode", connection_mode_schema()),
      #("details", ref("ClientDetails")),
      #("permission", string_array()),
      #("user", ref("User")),
      #("scopes", string_array()),
      #("timestamp", int_type()),
    ],
    ["mode", "details", "permission", "user", "scopes"],
  )
}

fn sequenced_client_schema() -> Json {
  object_schema(
    [
      #("client", ref("Client")),
      #("sequence_number", int_type()),
    ],
    ["client", "sequence_number"],
  )
}

fn signal_client_schema() -> Json {
  object_schema(
    [
      #("client_id", string_type()),
      #("client", ref("Client")),
      #("client_connection_number", int_type()),
      #("reference_sequence_number", int_type()),
    ],
    ["client_id", "client"],
  )
}

fn service_configuration_schema() -> Json {
  object_schema(
    [
      #("block_size", int_type()),
      #("max_message_size", int_type()),
      #("noop_time_frequency", int_type()),
      #("noop_count_frequency", int_type()),
    ],
    ["block_size", "max_message_size"],
  )
}

fn trace_schema() -> Json {
  object_schema(
    [
      #("service", string_type()),
      #("action", string_type()),
      #("timestamp", int_type()),
    ],
    ["service", "action", "timestamp"],
  )
}

fn message_origin_schema() -> Json {
  object_schema(
    [
      #("id", string_type()),
      #("sequence_number", int_type()),
      #("minimum_sequence_number", int_type()),
    ],
    ["id", "sequence_number", "minimum_sequence_number"],
  )
}

fn document_message_schema() -> Json {
  object_schema(
    [
      #("client_sequence_number", int_type()),
      #("reference_sequence_number", int_type()),
      #("message_type", string_type()),
      #("contents", any_type()),
      #("metadata", any_type()),
      #("server_metadata", any_type()),
      #("traces", array_of(ref("Trace"))),
      #("compression", string_type()),
    ],
    [
      "client_sequence_number",
      "reference_sequence_number",
      "message_type",
      "contents",
    ],
  )
}

fn sequenced_document_message_schema() -> Json {
  object_schema(
    [
      #("client_id", nullable_string()),
      #("sequence_number", int_type()),
      #("minimum_sequence_number", int_type()),
      #("client_sequence_number", int_type()),
      #("reference_sequence_number", int_type()),
      #("message_type", string_type()),
      #("contents", any_type()),
      #("metadata", any_type()),
      #("server_metadata", any_type()),
      #("origin", ref("MessageOrigin")),
      #("traces", array_of(ref("Trace"))),
      #("timestamp", int_type()),
      #("data", string_type()),
    ],
    [
      "sequence_number",
      "minimum_sequence_number",
      "client_sequence_number",
      "reference_sequence_number",
      "message_type",
      "contents",
      "timestamp",
    ],
  )
}

fn token_claims_schema() -> Json {
  object_schema(
    [
      #("document_id", string_type()),
      #("scopes", string_array()),
      #("tenant_id", string_type()),
      #("user", ref("User")),
      #("issued_at", int_type()),
      #("expiration", int_type()),
      #("version", string_type()),
      #("jti", string_type()),
    ],
    [
      "document_id",
      "scopes",
      "tenant_id",
      "user",
      "issued_at",
      "expiration",
      "version",
    ],
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// Public API
// ─────────────────────────────────────────────────────────────────────────────

/// Generate JSON schema for all protocol types as a combined schema
pub fn generate_protocol_schema() -> Json {
  let defs = [
    #("ConnectionMode", connection_mode_schema()),
    #("User", user_schema()),
    #("ClientCapabilities", client_capabilities_schema()),
    #("ClientDetails", client_details_schema()),
    #("Client", client_schema()),
    #("SequencedClient", sequenced_client_schema()),
    #("SignalClient", signal_client_schema()),
    #("ServiceConfiguration", service_configuration_schema()),
    #("Trace", trace_schema()),
    #("MessageOrigin", message_origin_schema()),
    #("DocumentMessage", document_message_schema()),
    #("SequencedDocumentMessage", sequenced_document_message_schema()),
    #("Scope", scope_schema()),
    #("TokenClaims", token_claims_schema()),
  ]

  let root_props = [
    #("ConnectionMode", ref("ConnectionMode")),
    #("User", ref("User")),
    #("ClientCapabilities", ref("ClientCapabilities")),
    #("ClientDetails", ref("ClientDetails")),
    #("Client", ref("Client")),
    #("SequencedClient", ref("SequencedClient")),
    #("SignalClient", ref("SignalClient")),
    #("ServiceConfiguration", ref("ServiceConfiguration")),
    #("Trace", ref("Trace")),
    #("MessageOrigin", ref("MessageOrigin")),
    #("DocumentMessage", ref("DocumentMessage")),
    #("SequencedDocumentMessage", ref("SequencedDocumentMessage")),
    #("Scope", ref("Scope")),
    #("TokenClaims", ref("TokenClaims")),
  ]

  json.object([
    #("$schema", json.string("http://json-schema.org/draft-07/schema#")),
    #("type", json.string("object")),
    #("additionalProperties", json.bool(False)),
    #("properties", json.object(root_props)),
    #("$defs", json.object(defs)),
  ])
}
