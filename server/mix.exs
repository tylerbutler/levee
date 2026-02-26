defmodule Levee.MixProject do
  use Mix.Project

  def project do
    [
      app: :levee,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Levee.Application, []},
      extra_applications: [:logger, :runtime_tools, :inets, :ssl]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.3"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      # JWT authentication
      {:jose, "~> 1.11"},
      # CORS support
      {:cors_plug, "~> 3.0"},
      # Database (optional PostgreSQL backend)
      {:ecto_sql, "~> 3.12"},
      {:postgrex, "~> 0.19"},
      # Tenant ID generation
      {:unique_names_generator, "~> 0.2.0"},
      # WebSocket test client
      {:websockex, "~> 0.4", only: :test}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "gleam.build", "ecto.setup"],
      "gleam.build": &gleam_build/1,
      compile: ["gleam.build", "compile"],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"]
    ]
  end

  defp gleam_build(_args) do
    gleam_projects = ["levee_protocol", "levee_auth", "levee_oauth", "../../beryl", "../levee_channels"]

    Enum.each(gleam_projects, fn gleam_path ->
      if File.dir?(gleam_path) do
        case System.cmd("gleam", ["build", "--target", "erlang"],
               cd: gleam_path,
               stderr_to_stdout: true
             ) do
          {output, 0} ->
            if String.contains?(output, "Compiling") do
              Mix.shell().info(output)
            end

            :ok

          {output, _exit_code} ->
            Mix.shell().error("Gleam compilation failed for #{gleam_path}:")
            Mix.shell().error(output)
            Mix.raise("Gleam compilation failed")
        end
      end
    end)
  end
end
