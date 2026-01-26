defmodule FluidServerWeb.HealthController do
  @moduledoc """
  Health check controller for the Fluid Framework server.
  """

  use FluidServerWeb, :controller

  @doc """
  Health check endpoint.

  GET /health

  Returns a simple OK response to indicate the server is running.
  """
  def index(conn, _params) do
    conn
    |> put_status(:ok)
    |> json(%{status: "ok"})
  end
end
