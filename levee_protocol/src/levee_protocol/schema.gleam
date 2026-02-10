/// JSON Schema generation for Levee protocol types
/// Uses json_blueprint to create decoders that can generate JSON Schema
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import json/blueprint as bp
import json/blueprint/schema as jsch

// For Dict(String, Dynamic) fields, we use a permissive object schema
fn dynamic_dict_decoder() -> bp.Decoder(json.Json) {
  bp.Decoder(
    fn(_input) { Ok(json.string("dynamic")) },
    jsch.DetailedObject(
      None,
      None,
      Some(jsch.TrueValue),
      None,
      None,
      None,
      None,
    ),
    [],
  )
}

// For Dynamic fields, we use a permissive schema
fn dynamic_decoder() -> bp.Decoder(json.Json) {
  bp.Decoder(fn(_input) { Ok(json.null()) }, jsch.TrueValue, [])
}

/// Decoder for ConnectionMode enum
pub fn connection_mode_decoder() -> bp.Decoder(String) {
  bp.enum_type_decoder([#("write", "write"), #("read", "read")])
}

/// Decoder for User type
pub fn user_decoder() -> bp.Decoder(#(String, json.Json)) {
  bp.decode2(
    fn(id, props) { #(id, props) },
    bp.field("id", bp.string()),
    bp.field("properties", dynamic_dict_decoder()),
  )
  |> bp.reuse_decoder
}

/// Decoder for ClientCapabilities type
pub fn client_capabilities_decoder() -> bp.Decoder(Bool) {
  bp.decode1(
    fn(interactive) { interactive },
    bp.field("interactive", bp.bool()),
  )
  |> bp.reuse_decoder
}

/// Decoder for ClientDetails type
pub fn client_details_decoder() -> bp.Decoder(
  #(Bool, Option(String), Option(String), Option(String)),
) {
  bp.decode4(
    fn(capabilities, client_type, environment, device) {
      #(capabilities, client_type, environment, device)
    },
    bp.field("capabilities", client_capabilities_decoder()),
    bp.optional_field("client_type", bp.string()),
    bp.optional_field("environment", bp.string()),
    bp.optional_field("device", bp.string()),
  )
  |> bp.reuse_decoder
}

/// Decoder for Client type
pub fn client_decoder() -> bp.Decoder(
  #(
    String,
    #(Bool, Option(String), Option(String), Option(String)),
    List(String),
    #(String, json.Json),
    List(String),
    Option(Int),
  ),
) {
  bp.decode6(
    fn(mode, details, permission, user, scopes, timestamp) {
      #(mode, details, permission, user, scopes, timestamp)
    },
    bp.field("mode", connection_mode_decoder()),
    bp.field("details", client_details_decoder()),
    bp.field("permission", bp.list(bp.string())),
    bp.field("user", user_decoder()),
    bp.field("scopes", bp.list(bp.string())),
    bp.optional_field("timestamp", bp.int()),
  )
  |> bp.reuse_decoder
}

/// Decoder for SequencedClient type
pub fn sequenced_client_decoder() -> bp.Decoder(#(json.Json, Int)) {
  bp.decode2(
    fn(client, seq) { #(client, seq) },
    bp.field("client", client_decoder() |> bp.map(fn(_) { json.null() })),
    bp.field("sequence_number", bp.int()),
  )
  |> bp.reuse_decoder
}

/// Decoder for SignalClient type
pub fn signal_client_decoder() -> bp.Decoder(
  #(String, json.Json, Option(Int), Option(Int)),
) {
  bp.decode4(
    fn(client_id, client, conn_num, ref_seq) {
      #(client_id, client, conn_num, ref_seq)
    },
    bp.field("client_id", bp.string()),
    bp.field("client", client_decoder() |> bp.map(fn(_) { json.null() })),
    bp.optional_field("client_connection_number", bp.int()),
    bp.optional_field("reference_sequence_number", bp.int()),
  )
  |> bp.reuse_decoder
}

/// Decoder for ServiceConfiguration type
pub fn service_configuration_decoder() -> bp.Decoder(
  #(Int, Int, Option(Int), Option(Int)),
) {
  bp.decode4(
    fn(block_size, max_msg_size, noop_time, noop_count) {
      #(block_size, max_msg_size, noop_time, noop_count)
    },
    bp.field("block_size", bp.int()),
    bp.field("max_message_size", bp.int()),
    bp.optional_field("noop_time_frequency", bp.int()),
    bp.optional_field("noop_count_frequency", bp.int()),
  )
  |> bp.reuse_decoder
}

/// Decoder for Trace type
pub fn trace_decoder() -> bp.Decoder(#(String, String, Int)) {
  bp.decode3(
    fn(service, action, timestamp) { #(service, action, timestamp) },
    bp.field("service", bp.string()),
    bp.field("action", bp.string()),
    bp.field("timestamp", bp.int()),
  )
  |> bp.reuse_decoder
}

/// Decoder for MessageOrigin type
pub fn message_origin_decoder() -> bp.Decoder(#(String, Int, Int)) {
  bp.decode3(
    fn(id, seq, min_seq) { #(id, seq, min_seq) },
    bp.field("id", bp.string()),
    bp.field("sequence_number", bp.int()),
    bp.field("minimum_sequence_number", bp.int()),
  )
  |> bp.reuse_decoder
}

/// Decoder for DocumentMessage type
pub fn document_message_decoder() -> bp.Decoder(
  #(
    Int,
    Int,
    String,
    json.Json,
    Option(json.Json),
    Option(json.Json),
    Option(List(#(String, String, Int))),
    Option(String),
  ),
) {
  bp.decode8(
    fn(
      csn,
      rsn,
      msg_type,
      contents,
      metadata,
      server_metadata,
      traces,
      compression,
    ) {
      #(
        csn,
        rsn,
        msg_type,
        contents,
        metadata,
        server_metadata,
        traces,
        compression,
      )
    },
    bp.field("client_sequence_number", bp.int()),
    bp.field("reference_sequence_number", bp.int()),
    bp.field("message_type", bp.string()),
    bp.field("contents", dynamic_decoder()),
    bp.optional_field("metadata", dynamic_decoder()),
    bp.optional_field("server_metadata", dynamic_decoder()),
    bp.optional_field("traces", bp.list(trace_decoder())),
    bp.optional_field("compression", bp.string()),
  )
  |> bp.reuse_decoder
}

/// Decoder for SequencedDocumentMessage type
pub fn sequenced_document_message_decoder() -> bp.Decoder(
  #(
    Option(String),
    Int,
    Int,
    Int,
    Int,
    String,
    json.Json,
    Option(json.Json),
    Option(json.Json),
    Option(#(String, Int, Int)),
    Option(List(#(String, String, Int))),
    Int,
  ),
) {
  // Using decode9 for first 9 fields plus additional handling
  // json_blueprint supports up to decode9, so we'll split this into two parts
  // For schema generation, we'll create a combined schema manually
  let schema =
    jsch.Object(
      [
        #("client_id", jsch.Nullable(jsch.Type(jsch.StringType))),
        #("sequence_number", jsch.Type(jsch.IntegerType)),
        #("minimum_sequence_number", jsch.Type(jsch.IntegerType)),
        #("client_sequence_number", jsch.Type(jsch.IntegerType)),
        #("reference_sequence_number", jsch.Type(jsch.IntegerType)),
        #("message_type", jsch.Type(jsch.StringType)),
        #("contents", jsch.TrueValue),
        #("metadata", jsch.Optional(jsch.TrueValue)),
        #("server_metadata", jsch.Optional(jsch.TrueValue)),
        #("origin", jsch.Optional(message_origin_decoder().schema)),
        #("traces", jsch.Optional(jsch.Array(Some(trace_decoder().schema)))),
        #("timestamp", jsch.Type(jsch.IntegerType)),
        #("data", jsch.Optional(jsch.Type(jsch.StringType))),
      ],
      Some(False),
      Some([
        "sequence_number",
        "minimum_sequence_number",
        "client_sequence_number",
        "reference_sequence_number",
        "message_type",
        "contents",
        "timestamp",
      ]),
    )

  bp.Decoder(
    fn(_input) {
      Ok(#(None, 0, 0, 0, 0, "", json.null(), None, None, None, None, 0))
    },
    schema,
    [],
  )
  |> bp.reuse_decoder
}

/// Decoder for Scope enum
pub fn scope_decoder() -> bp.Decoder(String) {
  bp.enum_type_decoder([
    #("doc:read", "doc:read"),
    #("doc:write", "doc:write"),
    #("summary:write", "summary:write"),
  ])
}

/// Decoder for TokenClaims type
pub fn token_claims_decoder() -> bp.Decoder(
  #(
    String,
    List(String),
    String,
    #(String, json.Json),
    Int,
    Int,
    String,
    Option(String),
  ),
) {
  bp.decode8(
    fn(doc_id, scopes, tenant_id, user, iat, exp, version, jti) {
      #(doc_id, scopes, tenant_id, user, iat, exp, version, jti)
    },
    bp.field("document_id", bp.string()),
    bp.field("scopes", bp.list(bp.string())),
    bp.field("tenant_id", bp.string()),
    bp.field("user", user_decoder()),
    bp.field("issued_at", bp.int()),
    bp.field("expiration", bp.int()),
    bp.field("version", bp.string()),
    bp.optional_field("jti", bp.string()),
  )
  |> bp.reuse_decoder
}

/// Helper to collect decoder schema and defs as a named definition
fn collect_decoder(
  name: String,
  decoder: bp.Decoder(a),
) -> #(#(String, jsch.SchemaDefinition), List(#(String, jsch.SchemaDefinition))) {
  #(#(name, decoder.schema), decoder.defs)
}

/// Generate JSON schema for all protocol types as a combined schema
pub fn generate_protocol_schema() -> json.Json {
  // Type names to export
  let type_names = [
    "ConnectionMode",
    "User",
    "ClientCapabilities",
    "ClientDetails",
    "Client",
    "SequencedClient",
    "SignalClient",
    "ServiceConfiguration",
    "Trace",
    "MessageOrigin",
    "DocumentMessage",
    "SequencedDocumentMessage",
    "Scope",
    "TokenClaims",
  ]

  // Collect all decoders with their names
  let collected = [
    collect_decoder("ConnectionMode", connection_mode_decoder()),
    collect_decoder("User", user_decoder()),
    collect_decoder("ClientCapabilities", client_capabilities_decoder()),
    collect_decoder("ClientDetails", client_details_decoder()),
    collect_decoder("Client", client_decoder()),
    collect_decoder("SequencedClient", sequenced_client_decoder()),
    collect_decoder("SignalClient", signal_client_decoder()),
    collect_decoder("ServiceConfiguration", service_configuration_decoder()),
    collect_decoder("Trace", trace_decoder()),
    collect_decoder("MessageOrigin", message_origin_decoder()),
    collect_decoder("DocumentMessage", document_message_decoder()),
    collect_decoder(
      "SequencedDocumentMessage",
      sequenced_document_message_decoder(),
    ),
    collect_decoder("Scope", scope_decoder()),
    collect_decoder("TokenClaims", token_claims_decoder()),
  ]

  // Extract named definitions
  let named_defs = list.map(collected, fn(c) { c.0 })

  // Collect all nested defs from reuse_decoder
  let nested_defs = list.flat_map(collected, fn(c) { c.1 })

  // Merge all definitions
  let all_defs = list.append(named_defs, nested_defs)

  // Create root properties that reference each type definition
  // This ensures json-schema-to-typescript generates all types
  let root_properties =
    list.map(type_names, fn(name) { #(name, jsch.Ref("#/$defs/" <> name)) })

  // Root schema wraps all definitions with properties referencing them
  let schema =
    jsch.new_schema(
      jsch.Object(root_properties, Some(False), None),
      Some(all_defs),
    )

  jsch.to_json(schema)
}

/// Generate JSON schema for individual decoders
pub fn generate_schema(decoder: bp.Decoder(a)) -> json.Json {
  bp.generate_json_schema(decoder)
}
