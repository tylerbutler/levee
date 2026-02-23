import Config

config :levee, env: :test

# Configure the Store for test
config :levee, Levee.Store,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "levee_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

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

# Disable ueberauth in tests (we mock the callbacks)
config :ueberauth, Ueberauth.Strategy.Github.OAuth,
  client_id: "test_client_id",
  client_secret: "test_client_secret"
