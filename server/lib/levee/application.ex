defmodule Levee.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Add Gleam compiled modules to the code path
    load_gleam_modules()

    children =
      maybe_start_repo() ++
        [
          LeveeWeb.Telemetry,
          {DNSCluster, query: Application.get_env(:levee, :dns_cluster_query) || :ignore},
          {Phoenix.PubSub, name: Levee.PubSub},
          # ETS-based storage backend (must start before other services)
          Levee.Storage.ETS,
          # Registry for looking up document sessions by {tenant_id, document_id}
          {Registry, keys: :unique, name: Levee.SessionRegistry},
          # Tenant secrets for JWT authentication
          Levee.Auth.TenantSecrets,
          # In-memory user/session store (dev/test only, replaced by DB in prod)
          Levee.Auth.SessionStore,
          # DynamicSupervisor for document sessions
          Levee.Documents.Supervisor,
          # Beryl channels coordinator (must start before Endpoint)
          Levee.Channels,
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

  # Project root captured at compile time for reliable path resolution
  @app_root Path.expand("../..", __DIR__)

  # Load Gleam compiled BEAM files into the code path
  defp load_gleam_modules do
    app_root = @app_root

    # Try multiple possible locations for Gleam build output:
    # 1. Development: relative to app root (mix compile)
    # 2. Release: in /app/<package> (Docker)
    repo_root = Path.expand("..", app_root)

    base_paths = [
      Path.join([app_root, "levee_protocol", "build", "dev", "erlang"]),
      Path.join([app_root, "levee_auth", "build", "dev", "erlang"]),
      Path.join([repo_root, "beryl", "build", "dev", "erlang"]),
      Path.join([repo_root, "levee_channels", "build", "dev", "erlang"]),
      "/app/levee_protocol/build/dev/erlang",
      "/app/levee_auth/build/dev/erlang",
      "/app/beryl/build/dev/erlang",
      "/app/levee_channels/build/dev/erlang"
    ]

    gleam_modules = [
      "levee_protocol",
      "levee_auth",
      "beryl",
      "levee_channels",
      "gleam_stdlib",
      "gleam_crypto",
      "gleam_json",
      "gleam_time",
      "gleam_erlang",
      "gleam_otp",
      "youid"
    ]

    # Add all ebin paths to the code path
    for base <- base_paths, mod <- gleam_modules do
      path = Path.join([base, mod, "ebin"]) |> Path.expand()

      if File.dir?(path) do
        :code.add_patha(String.to_charlist(path))
      end
    end

    # Collect unique BEAM files across all paths, loading each module only once.
    # Shared deps (gleam_stdlib, etc.) exist in multiple Gleam package builds;
    # loading the same module twice causes :not_purged errors.
    beam_files =
      for base <- base_paths, mod <- gleam_modules, reduce: MapSet.new() do
        acc ->
          ebin_path = Path.join([base, mod, "ebin"]) |> Path.expand()

          if File.dir?(ebin_path) do
            ebin_path
            |> File.ls!()
            |> Enum.filter(&String.ends_with?(&1, ".beam"))
            |> Enum.map(&String.trim_trailing(&1, ".beam"))
            |> Enum.reduce(acc, &MapSet.put(&2, &1))
          else
            acc
          end
      end

    Enum.each(beam_files, fn module_name ->
      :code.load_file(String.to_atom(module_name))
    end)
  end

  # Only start the Repo if database is configured and available
  defp maybe_start_repo do
    if Application.get_env(:levee, :start_repo, true) do
      [Levee.Repo]
    else
      []
    end
  end
end
