defmodule Mix.Tasks.GenerateSchema do
  @moduledoc """
  Generates JSON schema from Gleam protocol types.

  Usage:
      mix generate_schema

  This task runs the Gleam schema CLI and writes the output to priv/protocol-schema.json.
  """
  use Mix.Task

  @shortdoc "Generate JSON schema from Gleam protocol types"

  @impl Mix.Task
  def run(_args) do
    Mix.shell().info("Generating JSON schema from Gleam protocol types...")

    # Ensure Gleam is built (stderr goes to console)
    {_, 0} = System.cmd("gleam", ["build"], cd: "levee_protocol", into: IO.stream(:stdio, :line))

    # Run the schema CLI - use a port to separate stdout and stderr
    port =
      Port.open(
        {:spawn_executable, System.find_executable("gleam")},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: ["run", "-m", "schema_cli"],
          cd: ~c"levee_protocol"
        ]
      )

    output = collect_port_output(port, "")

    case output do
      {:ok, data} ->
        # Extract JSON from the output (skip any Gleam compilation messages)
        json_str = extract_json(data)

        # Pretty-print the JSON
        case Jason.decode(json_str) do
          {:ok, json} ->
            pretty_json = Jason.encode!(json, pretty: true)

            # Ensure priv directory exists
            File.mkdir_p!("priv")

            # Write the schema
            File.write!("priv/protocol-schema.json", pretty_json)
            Mix.shell().info("Schema written to priv/protocol-schema.json")

          {:error, reason} ->
            Mix.shell().error("Failed to parse JSON: #{inspect(reason)}")
            Mix.shell().error("Output was: #{String.slice(json_str, 0, 500)}")
            exit({:shutdown, 1})
        end

      {:error, exit_code, data} ->
        Mix.shell().error("Failed to generate schema (exit code #{exit_code}):")
        Mix.shell().error(data)
        exit({:shutdown, exit_code})
    end
  end

  defp collect_port_output(port, acc) do
    receive do
      {^port, {:data, data}} ->
        collect_port_output(port, acc <> data)

      {^port, {:exit_status, 0}} ->
        {:ok, acc}

      {^port, {:exit_status, code}} ->
        {:error, code, acc}
    after
      60_000 ->
        Port.close(port)
        {:error, :timeout, acc}
    end
  end

  defp extract_json(data) do
    # Find the start of JSON (first '{')
    case String.split(data, ~r/\{/, parts: 2) do
      [_, rest] -> "{" <> rest
      _ -> data
    end
  end
end
