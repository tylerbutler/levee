defmodule Levee.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Add Gleam compiled modules to the code path
    load_gleam_modules()

    children = [
      LeveeWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:levee, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Levee.PubSub},
      # ETS-based storage backend (must start before other services)
      Levee.Storage.ETS,
      # Registry for looking up document sessions by {tenant_id, document_id}
      {Registry, keys: :unique, name: Levee.SessionRegistry},
      # Tenant secrets for JWT authentication
      Levee.Auth.TenantSecrets,
      # DynamicSupervisor for document sessions
      Levee.Documents.Supervisor,
      # Registry manager
      Levee.Documents.Registry,
      # Start to serve requests, typically the last entry
      LeveeWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Levee.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    LeveeWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  # Load Gleam compiled BEAM files into the code path
  defp load_gleam_modules do
    priv_dir = :code.priv_dir(:levee) |> to_string()
    app_root = Path.join([priv_dir, ".."])

    # Try multiple possible locations for Gleam build output:
    # 1. Development: relative to app root (mix compile)
    # 2. Release: in /app/levee_protocol (Docker)
    base_paths = [
      Path.join([app_root, "levee_protocol", "build", "dev", "erlang"]),
      "/app/levee_protocol/build/dev/erlang"
    ]

    gleam_modules = ["levee_protocol", "gleam_stdlib"]

    for base <- base_paths, mod <- gleam_modules do
      path = Path.join([base, mod, "ebin"]) |> Path.expand()

      if File.dir?(path) do
        :code.add_patha(String.to_charlist(path))
      end
    end

    # Explicitly load the levee_protocol module to ensure it's available
    case :code.load_file(:levee_protocol) do
      {:module, _} -> :ok
      {:error, reason} -> IO.warn("Failed to load levee_protocol: #{inspect(reason)}")
    end
  end
end
