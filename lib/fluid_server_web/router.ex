defmodule FluidServerWeb.Router do
  use FluidServerWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api", FluidServerWeb do
    pipe_through :api
  end
end
