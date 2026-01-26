/// CLI entry point for generating JSON schema from Levee protocol types
/// Run with: gleam run -m schema_cli

import gleam/io
import gleam/json
import levee_protocol/schema

pub fn main() {
  schema.generate_protocol_schema()
  |> json.to_string()
  |> io.println()
}
