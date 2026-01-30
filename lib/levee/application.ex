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
      # Start to serve requests, typically the last entry
      LeveeWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Levee.Supervisor]
    result = Supervisor.start_link(children, opts)

    # Register dev tenant in dev/test environments
    case result do
      {:ok, _pid} ->
        register_dev_tenants()

      _ ->
        :ok
    end

    result
  end

  defp register_dev_tenants do
    if Application.get_env(:levee, :env) in [:dev, :test] do
      Levee.Auth.TenantSecrets.register_dev_tenant("dev-tenant")
    end
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

    # Explicitly load all Gleam modules to ensure they're available
    # Gleam creates separate BEAM files for each submodule (e.g., levee_protocol@sequencing, gleam@dict)
    for base <- base_paths, mod <- gleam_modules do
      ebin_path = Path.join([base, mod, "ebin"]) |> Path.expand()

      if File.dir?(ebin_path) do
        ebin_path
        |> File.ls!()
        |> Enum.filter(&String.ends_with?(&1, ".beam"))
        |> Enum.map(&String.trim_trailing(&1, ".beam"))
        |> Enum.each(fn module_name ->
          module_atom = String.to_atom(module_name)
          :code.load_file(module_atom)
        end)
      end
    end
  end
end
