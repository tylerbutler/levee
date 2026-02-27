# Load Gleam compiled BEAM files into the code path before tests
app_root = Path.expand("../", __DIR__)

gleam_paths = [
  # levee_protocol paths
  Path.join([app_root, "levee_protocol", "build", "dev", "erlang", "levee_protocol", "ebin"]),
  Path.join([app_root, "levee_protocol", "build", "dev", "erlang", "gleam_stdlib", "ebin"]),
  # levee_auth paths
  Path.join([app_root, "levee_auth", "build", "dev", "erlang", "levee_auth", "ebin"]),
  Path.join([app_root, "levee_auth", "build", "dev", "erlang", "gleam_stdlib", "ebin"]),
  Path.join([app_root, "levee_auth", "build", "dev", "erlang", "gleam_crypto", "ebin"]),
  Path.join([app_root, "levee_auth", "build", "dev", "erlang", "gleam_json", "ebin"]),
  Path.join([app_root, "levee_auth", "build", "dev", "erlang", "gleam_time", "ebin"]),
  Path.join([app_root, "levee_auth", "build", "dev", "erlang", "youid", "ebin"]),
  # beryl paths (external repo at workspace root)
  Path.join([app_root, "..", "..", "beryl", "build", "dev", "erlang", "beryl", "ebin"]),
  Path.join([app_root, "..", "..", "beryl", "build", "dev", "erlang", "gleam_otp", "ebin"]),
  Path.join([app_root, "..", "..", "beryl", "build", "dev", "erlang", "gleam_erlang", "ebin"]),
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

ExUnit.start(exclude: [:postgres])
