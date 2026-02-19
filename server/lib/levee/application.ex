defmodule Levee.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Add Gleam compiled modules to the code path
    load_gleam_modules()

    # Start storage backend based on configuration
    storage_children = storage_children()

    children =
      [
        LeveeWeb.Telemetry,
        {DNSCluster, query: Application.get_env(:levee, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Levee.PubSub}
      ] ++
        storage_children ++
        [
          # Registry for looking up document sessions by {tenant_id, document_id}
          {Registry, keys: :unique, name: Levee.SessionRegistry},
          # Tenant secrets for JWT authentication
          Levee.Auth.TenantSecrets,
          # In-memory user/session store (dev/test only, replaced by DB in prod)
          Levee.Auth.SessionStore,
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

  # Return the appropriate storage backend children based on configuration
  defp storage_children do
    case Application.get_env(:levee, :storage_backend, Levee.Storage.ETS) do
      Levee.Storage.Postgres ->
        # PostgreSQL backend - start Store
        [Levee.Store]

      Levee.Storage.ETS ->
        # ETS backend (default)
        [Levee.Storage.ETS]

      _other ->
        # Default to ETS
        [Levee.Storage.ETS]
    end
  end

  # Load Gleam compiled BEAM files into the code path
  defp load_gleam_modules do
    # In dev, Gleam packages are siblings in the project root (File.cwd!()).
    # priv_dir points into _build/ which is NOT the project root.
    project_root = File.cwd!()

    base_paths =
      for pkg <- ["levee_protocol", "levee_auth"] do
        Path.join([project_root, pkg, "build", "dev", "erlang"])
      end ++
        [
          # Release: in /app/<package> (Docker)
          "/app/levee_protocol/build/dev/erlang",
          "/app/levee_auth/build/dev/erlang"
        ]

    gleam_modules = [
      "levee_protocol",
      "levee_auth",
      "gleam_stdlib",
      "gleam_crypto",
      "gleam_json",
      "gleam_time",
      "youid"
    ]

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

    # Verify critical Gleam modules loaded successfully
    required_modules = [:levee_protocol, :password_ffi]

    Enum.each(required_modules, fn mod ->
      case :code.ensure_loaded(mod) do
        {:module, ^mod} ->
          :ok

        {:error, reason} ->
          require Logger

          Logger.error(
            "Failed to load required Gleam module #{mod}: #{inspect(reason)}. " <>
              "Run 'just build-gleam' to compile Gleam packages."
          )
      end
    end)
  end
end
