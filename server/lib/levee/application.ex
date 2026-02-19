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
    # In dev/test, the project root is File.cwd!() (where mix.exs lives).
    # In releases, Gleam packages are copied to /app/<package>.
    project_root = File.cwd!()

    gleam_packages = ["levee_protocol", "levee_auth"]

    base_paths =
      Enum.flat_map(gleam_packages, fn pkg ->
        [
          Path.join([project_root, pkg, "build", "dev", "erlang"]),
          Path.join(["/app", pkg, "build", "dev", "erlang"])
        ]
      end)

    # Find all ebin directories under each base path and add them to the code path
    for base <- base_paths, File.dir?(base) do
      base
      |> File.ls!()
      |> Enum.map(&Path.join([base, &1, "ebin"]))
      |> Enum.filter(&File.dir?/1)
      |> Enum.each(fn ebin_path ->
        :code.add_patha(String.to_charlist(ebin_path))
      end)
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
