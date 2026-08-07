# Load Gleam compiled BEAM files into the code path before tests
app_root = Path.expand("../", __DIR__)

gleam_paths = [
  # spillway protocol paths (pulled in via the floodgate package)
  Path.join([app_root, "floodgate", "build", "dev", "erlang", "spillway", "ebin"]),
  Path.join([app_root, "floodgate", "build", "dev", "erlang", "gleam_stdlib", "ebin"]),
  # levee_auth paths
  Path.join([app_root, "levee_auth", "build", "dev", "erlang", "levee_auth", "ebin"]),
  Path.join([app_root, "levee_auth", "build", "dev", "erlang", "gleam_stdlib", "ebin"]),
  Path.join([app_root, "levee_auth", "build", "dev", "erlang", "gleam_crypto", "ebin"]),
  Path.join([app_root, "levee_auth", "build", "dev", "erlang", "gleam_json", "ebin"]),
  Path.join([app_root, "levee_auth", "build", "dev", "erlang", "gleam_time", "ebin"]),
  Path.join([app_root, "levee_auth", "build", "dev", "erlang", "youid", "ebin"]),
  # levee_storage paths (for PG backend)
  Path.join([app_root, "levee_storage", "build", "dev", "erlang", "levee_storage", "ebin"]),
  Path.join([app_root, "levee_storage", "build", "dev", "erlang", "pog", "ebin"]),
  Path.join([app_root, "levee_storage", "build", "dev", "erlang", "pgo", "ebin"]),
  Path.join([app_root, "levee_storage", "build", "dev", "erlang", "pg_types", "ebin"]),
  Path.join([app_root, "levee_storage", "build", "dev", "erlang", "backoff", "ebin"]),
  Path.join([app_root, "levee_storage", "build", "dev", "erlang", "opentelemetry_api", "ebin"]),
  Path.join([app_root, "levee_storage", "build", "dev", "erlang", "gleam_otp", "ebin"]),
  Path.join([app_root, "levee_storage", "build", "dev", "erlang", "gleam_erlang", "ebin"])
]

Enum.each(gleam_paths, fn path ->
  if File.dir?(path) do
    :code.add_patha(String.to_charlist(path))
  end
end)

# Start the pgo application if DATABASE_URL is set (needed for PG storage tests)
if System.get_env("DATABASE_URL") do
  Application.ensure_all_started(:backoff)
  Application.ensure_all_started(:opentelemetry_api)
  Application.ensure_all_started(:pg_types)
  Application.ensure_all_started(:pgo)
end

# config/test.exs points each run at its own DETS directory so no run can
# inherit document IDs from an earlier one. Remove it on the way out — the
# application already opened its tables there, so it cannot be deleted now.
# Levee.Storage.DataDirIsolationTest asserts this teardown is registered.
storage_data_dir = Application.get_env(:levee, :storage_data_dir)

if is_binary(storage_data_dir) do
  System.at_exit(fn _status -> File.rm_rf(storage_data_dir) end)
  :persistent_term.put(:levee_test_storage_cleanup_registered, true)
end

ExUnit.start(exclude: [:postgres])
