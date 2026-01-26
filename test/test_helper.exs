# Load Gleam compiled BEAM files into the code path before tests
app_root = Path.expand("../", __DIR__)

gleam_paths = [
  Path.join([app_root, "levee_protocol", "build", "dev", "erlang", "levee_protocol", "ebin"]),
  Path.join([app_root, "levee_protocol", "build", "dev", "erlang", "gleam_stdlib", "ebin"])
]

Enum.each(gleam_paths, fn path ->
  if File.dir?(path) do
    :code.add_patha(String.to_charlist(path))
  end
end)

# Set up database sandbox mode if using PostgreSQL backend
if Application.get_env(:levee, :storage_backend) == Levee.Storage.Postgres do
  Ecto.Adapters.SQL.Sandbox.mode(Levee.Repo, :manual)
end

ExUnit.start()
