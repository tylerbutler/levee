defmodule Levee.MixProject do
  @moduledoc """
  Minimal mix project for compiling the document Session GenServer.

  The main web server runs via `gleam run` in levee_web/.
  This mix project only exists to compile session.ex, registry.ex,
  and supervisor.ex into BEAM modules that levee_web loads via FFI.

  Will be removed when the Session GenServer is ported to Gleam.
  """

  use Mix.Project

  def project do
    [
      app: :levee,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: ["lib"],
      start_permanent: false,
      deps: []
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end
end
