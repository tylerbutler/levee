import Config

config :levee, env: :test

# Give every test run its own DETS store.
#
# GleamETS persists documents and reloads them on boot, while test document IDs
# (System.unique_integer/1) are only unique within a single VM run. Sharing one
# store — the dev store at priv/storage/dets — let documents accumulate across
# runs forever, so a fresh ID could collide with residue from an earlier run and
# fail whichever test lost the race with {:error, :already_exists}.
#
# This must be a fresh path rather than a wipe of a fixed one: `mix test` starts
# the application *before* test_helper.exs runs, so deleting a fixed directory
# there would unlink the DETS files under already-open tables. test_helper.exs
# removes this directory at exit instead.
config :levee,
  storage_data_dir:
    Path.join([
      System.tmp_dir!(),
      "levee-test-storage",
      "run-#{System.pid()}-#{System.system_time(:nanosecond)}"
    ])

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :levee, LeveeWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "8PZb5iIoVUTFLp1GGZj4pAWbgKopNS9JYOoUw1ajc+bSQkAONOB7+2R99ZyPlPws",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
