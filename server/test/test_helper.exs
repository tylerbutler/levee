# Load Gleam compiled BEAM files into the code path before tests.
# Dynamically discover all ebin dirs so new Gleam deps are picked up automatically.
app_root = Path.expand("../", __DIR__)

for gleam_pkg <- ["levee_protocol", "levee_auth"] do
  erlang_dir = Path.join([app_root, gleam_pkg, "build", "dev", "erlang"])

  if File.dir?(erlang_dir) do
    erlang_dir
    |> File.ls!()
    |> Enum.each(fn pkg_name ->
      ebin_path = Path.join([erlang_dir, pkg_name, "ebin"])

      if File.dir?(ebin_path) do
        :code.add_patha(String.to_charlist(ebin_path))
      end
    end)
  end
end

# Set up database sandbox mode if using PostgreSQL backend
if Application.get_env(:levee, :storage_backend) == Levee.Storage.Postgres do
  Ecto.Adapters.SQL.Sandbox.mode(Levee.Store, :manual)
end

ExUnit.start()
