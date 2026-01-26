defmodule FluidServer.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Add Gleam compiled modules to the code path
    load_gleam_modules()
    children = [
      FluidServerWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:fluid_server, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: FluidServer.PubSub},
      # Registry for looking up document sessions by {tenant_id, document_id}
      {Registry, keys: :unique, name: FluidServer.SessionRegistry},
      # DynamicSupervisor for document sessions
      FluidServer.Documents.Supervisor,
      # Registry manager
      FluidServer.Documents.Registry,
      # Start to serve requests, typically the last entry
      FluidServerWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: FluidServer.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    FluidServerWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  # Load Gleam compiled BEAM files into the code path
  defp load_gleam_modules do
    priv_dir = :code.priv_dir(:fluid_server) |> to_string()
    app_root = Path.join([priv_dir, ".."])

    # Gleam build output paths
    gleam_paths = [
      Path.join([app_root, "gleam_protocol", "build", "dev", "erlang", "fluid_protocol", "ebin"]),
      Path.join([app_root, "gleam_protocol", "build", "dev", "erlang", "gleam_stdlib", "ebin"])
    ]

    Enum.each(gleam_paths, fn path ->
      expanded = Path.expand(path)
      if File.dir?(expanded) do
        :code.add_patha(String.to_charlist(expanded))
      end
    end)
  end
end
