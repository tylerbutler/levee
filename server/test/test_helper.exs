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
  Path.join([app_root, "levee_auth", "build", "dev", "erlang", "youid", "ebin"])
]

Enum.each(gleam_paths, fn path ->
  if File.dir?(path) do
    :code.add_patha(String.to_charlist(path))
  end
end)

# Set up database sandbox mode if using PostgreSQL backend

ExUnit.start(exclude: [:postgres])
