# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :levee,
  generators: [timestamp_type: :utc_datetime],
  ecto_repos: [Levee.Store],
  # Storage backend: Levee.Storage.GleamETS (default) or Levee.Storage.Postgres
  storage_backend: Levee.Storage.GleamETS,
  # GitHub username allow list for OAuth login. nil = allow all, [] = allow none.
  # Override via GITHUB_ALLOWED_USERS env var (comma-separated).
  github_allowed_users: nil,
  # GitHub team allow list for OAuth login. nil = no team restriction.
  # Override via GITHUB_ALLOWED_TEAMS env var (comma-separated org/team-slug pairs).
  # If both allowed_users and allowed_teams are set, either check grants access (OR).
  github_allowed_teams: nil

# Configure the endpoint
config :levee, LeveeWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: LeveeWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Levee.PubSub,
  live_view: [signing_salt: "f2avchZV"]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
