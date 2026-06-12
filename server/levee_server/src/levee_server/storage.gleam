import gleam/dynamic.{type Dynamic}
import gleam/json
import levee_storage.{type Tables}

@external(erlang, "levee_server_ffi", "get_tables")
fn ffi_get_tables() -> Result(Tables, Nil)

@external(erlang, "levee_server_ffi", "put_tables")
fn ffi_put_tables(tables: Tables) -> Nil

@external(erlang, "levee_server_ffi", "dynamic_to_json")
pub fn dynamic_to_json(value: a) -> String

@external(erlang, "levee_server_ffi", "dynamic_to_base64")
pub fn dynamic_to_base64(value: a) -> String

@external(erlang, "gleam_stdlib", "identity")
pub fn json_fragment(value: String) -> json.Json

@external(erlang, "storage_ffi_helpers", "identity")
pub fn to_dynamic(value: a) -> Dynamic

@external(erlang, "storage_ffi_helpers", "json_string_to_dynamic")
pub fn json_string_to_dynamic(value: String) -> Dynamic

@external(erlang, "levee_server_ffi", "ensure_dir")
pub fn ensure_dir_for_test(path: String) -> Nil

pub fn get_tables() -> Result(Tables, Nil) {
  ffi_get_tables()
}

pub fn has_tables() -> Bool {
  case get_tables() {
    Ok(_) -> True
    Error(Nil) -> False
  }
}

pub fn put_tables_for_test(tables: Tables) -> Nil {
  ffi_put_tables(tables)
}
