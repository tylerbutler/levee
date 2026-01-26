defmodule FluidServerWeb.Router do
  use FluidServerWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Document Operations (Storage Service)
  scope "/documents", FluidServerWeb do
    pipe_through :api

    # POST /documents/:tenant_id - Create document
    post "/:tenant_id", DocumentController, :create

    # GET /documents/:tenant_id/session/:id - Get session info
    # Note: This must come before the generic :id route
    get "/:tenant_id/session/:id", DocumentController, :session

    # GET /documents/:tenant_id/:id - Get document metadata
    get "/:tenant_id/:id", DocumentController, :show
  end

  # Delta Operations (Storage Service)
  scope "/deltas", FluidServerWeb do
    pipe_through :api

    # GET /deltas/:tenant_id/:id - Get operations with pagination
    get "/:tenant_id/:id", DeltaController, :index
  end

  # Git Storage Operations (Historian Service)
  scope "/repos/:tenant_id/git", FluidServerWeb do
    pipe_through :api

    # Blob operations
    post "/blobs", GitController, :create_blob
    get "/blobs/:sha", GitController, :show_blob

    # Tree operations
    post "/trees", GitController, :create_tree
    get "/trees/:sha", GitController, :show_tree

    # Commit operations
    post "/commits", GitController, :create_commit
    get "/commits/:sha", GitController, :show_commit

    # Reference operations
    get "/refs", GitController, :list_refs
    post "/refs", GitController, :create_ref
    get "/refs/*ref", GitController, :show_ref
    patch "/refs/*ref", GitController, :update_ref
  end

  # Health check endpoint
  scope "/", FluidServerWeb do
    pipe_through :api

    get "/health", HealthController, :index
  end
end
