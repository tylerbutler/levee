import envoy
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process
import gleam/json
import gleam/result
import levee_storage.{type Tables}

const default_storage_data_dir = "priv/storage/dets"

const save_interval_ms = 5000

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

pub fn get_or_init_tables() -> Tables {
  case get_tables() {
    Ok(tables) -> tables
    Error(Nil) -> {
      let data_dir =
        envoy.get("LEVEE_STORAGE_DATA_DIR")
        |> result.unwrap(default_storage_data_dir)
      ensure_dir_for_test(data_dir)
      let tables = levee_storage.ets_init(data_dir)
      ffi_put_tables(tables)
      tables
    }
  }
}

pub fn start_periodic_saver(tables: Tables) -> Nil {
  let _ = process.spawn(fn() { periodic_save_loop(tables) })
  Nil
}

fn periodic_save_loop(tables: Tables) -> Nil {
  process.sleep(save_interval_ms)
  levee_storage.ets_save(tables)
  periodic_save_loop(tables)
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
