defmodule LeveeWeb.Router do
  use LeveeWeb, :router

  alias LeveeWeb.Plugs.Auth

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Authenticated API routes - requires valid JWT token
  pipeline :authenticated do
    plug :accepts, ["json"]
    plug Auth
  end

  # Read-only access - requires doc:read scope
  pipeline :read_access do
    plug :accepts, ["json"]
    plug Auth, scopes: ["doc:read"]
  end

  # Write access - requires doc:read and doc:write scopes
  pipeline :write_access do
    plug :accepts, ["json"]
    plug Auth, scopes: ["doc:read", "doc:write"]
  end

  # Summary write access - requires doc:read and summary:write scopes
  pipeline :summary_access do
    plug :accepts, ["json"]
    plug Auth, scopes: ["doc:read", "summary:write"]
  end

  # Session-based auth for auth management routes (me, logout)
  pipeline :session_auth do
    plug LeveeWeb.Plugs.SessionAuth
  end

  # Public API routes (health checks, etc.)
  scope "/", LeveeWeb do
    pipe_through :api

    get "/health", HealthController, :index
  end

  # Auth API routes (public - no JWT required)
  scope "/api/auth", LeveeWeb do
    pipe_through :api

    post "/register", AuthController, :register
    post "/login", AuthController, :login
  end

  # Auth API routes (require valid session)
  scope "/api/auth", LeveeWeb do
    pipe_through [:api, :session_auth]

    post "/logout", AuthController, :logout
    get "/me", AuthController, :me
  end

  # Document Operations (Storage Service) - write access for create
  scope "/documents", LeveeWeb do
    pipe_through :write_access

    # POST /documents/:tenant_id - Create document
    post "/:tenant_id", DocumentController, :create
  end

  # Document Operations (Storage Service) - read access for queries
  scope "/documents", LeveeWeb do
    pipe_through :read_access

    # GET /documents/:tenant_id/session/:id - Get session info
    # Note: This must come before the generic :id route
    get "/:tenant_id/session/:id", DocumentController, :session

    # GET /documents/:tenant_id/:id - Get document metadata
    get "/:tenant_id/:id", DocumentController, :show
  end

  # Delta Operations (Storage Service) - read access
  scope "/deltas", LeveeWeb do
    pipe_through :read_access

    # GET /deltas/:tenant_id/:id - Get operations with pagination
    get "/:tenant_id/:id", DeltaController, :index
  end

  # Git Storage Operations (Historian Service) - read operations
  scope "/repos/:tenant_id/git", LeveeWeb do
    pipe_through :read_access

    # Blob read operations
    get "/blobs/:sha", GitController, :show_blob

    # Tree read operations
    get "/trees/:sha", GitController, :show_tree

    # Commit read operations
    get "/commits/:sha", GitController, :show_commit

    # Reference read operations
    get "/refs", GitController, :list_refs
    get "/refs/*ref", GitController, :show_ref
  end

  # Git Storage Operations (Historian Service) - write operations (require summary:write)
  scope "/repos/:tenant_id/git", LeveeWeb do
    pipe_through :summary_access

    # Blob write operations
    post "/blobs", GitController, :create_blob

    # Tree write operations
    post "/trees", GitController, :create_tree

    # Commit write operations
    post "/commits", GitController, :create_commit

    # Reference write operations
    post "/refs", GitController, :create_ref
    patch "/refs/*ref", GitController, :update_ref
  end

  # Admin API routes (requires LEVEE_ADMIN_KEY)
  pipeline :admin_auth do
    plug :accepts, ["json"]
    plug LeveeWeb.Plugs.AdminAuth
  end

  scope "/api/admin", LeveeWeb do
    pipe_through :admin_auth

    get "/tenants", TenantAdminController, :index
    post "/tenants", TenantAdminController, :create
    get "/tenants/:id", TenantAdminController, :show
    put "/tenants/:id", TenantAdminController, :update
    delete "/tenants/:id", TenantAdminController, :delete
  end

  # Admin UI - SPA catch-all (serves index.html for all /admin/* paths)
  pipeline :browser do
    plug :accepts, ["html"]
  end

  scope "/admin", LeveeWeb do
    pipe_through :browser

    get "/", AdminController, :index
    get "/*path", AdminController, :index
  end
end
