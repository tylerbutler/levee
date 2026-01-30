---
name: new-endpoint
description: Create a new REST API endpoint with authentication
---

# Create New API Endpoint

Guide for adding a new REST endpoint to Levee.

## Prerequisites

1. Understand the endpoint requirements:
   - HTTP method (GET, POST, PATCH, DELETE)
   - URL path and parameters
   - Required authentication/authorization
   - Request/response schemas

## Step 1: Analyze Router Structure

Read `lib/levee_web/router.ex` to understand:
- Available pipelines and their auth requirements
- Existing route patterns
- Scope organization

### Available Pipelines

| Pipeline | Auth Level | Use For |
|----------|-----------|---------|
| `:api` | None | Public endpoints (health check) |
| `:authenticated` | Valid JWT | Basic auth, tenant validated |
| `:read_access` | JWT + `doc:read` | Read document data |
| `:write_access` | JWT + `doc:write` | Mutate document data |
| `:summary_access` | JWT + `summary:read` | Read git-like storage |
| `:summary_write_access` | JWT + `summary:write` | Write git-like storage |

## Step 2: Add Route

Add the route to `lib/levee_web/router.ex` in the appropriate scope:

```elixir
scope "/api", LeveeWeb do
  pipe_through [:api, :authenticated, :read_access]

  # Add your route
  get "/your-path/:tenant_id/:id", YourController, :show
end
```

## Step 3: Create/Update Controller

Create or update the controller in `lib/levee_web/controllers/`:

```elixir
defmodule LeveeWeb.YourController do
  use LeveeWeb, :controller

  def show(conn, %{"tenant_id" => tenant_id, "id" => id}) do
    # Access validated claims from auth plug
    claims = conn.assigns[:claims]

    # Verify tenant matches token (already done by auth plug)
    # Implement your logic

    case YourModule.get(tenant_id, id) do
      {:ok, data} ->
        json(conn, data)
      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "not_found"})
    end
  end
end
```

## Step 4: Add Tests

Create tests in `test/levee_web/controllers/`:

```elixir
defmodule LeveeWeb.YourControllerTest do
  use LeveeWeb.ConnCase, async: true

  @tenant_id "test-tenant"
  @document_id "test-doc"
  @user_id "test-user"

  setup do
    TenantSecrets.register_tenant(@tenant_id, "test-secret")
    on_exit(fn -> TenantSecrets.unregister_tenant(@tenant_id) end)
    :ok
  end

  describe "show/2" do
    test "returns data with valid token", %{conn: conn} do
      token = JWT.generate_test_token(@tenant_id, @document_id, @user_id)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/your-path/#{@tenant_id}/#{@document_id}")

      assert json_response(conn, 200)
    end

    test "returns 401 without token", %{conn: conn} do
      conn = get(conn, "/api/your-path/#{@tenant_id}/#{@document_id}")
      assert json_response(conn, 401)
    end
  end
end
```

## Step 5: Verify

```bash
# Run tests
mix test test/levee_web/controllers/your_controller_test.exs

# Run all tests
just test-elixir

# Manual test with curl
TOKEN=$(mix run -e 'IO.puts Levee.Auth.JWT.generate_test_token("dev-tenant", "doc", "user")')
curl -H "Authorization: Bearer $TOKEN" http://localhost:4000/api/your-path/dev-tenant/doc
```

## Common Patterns

### Extracting Path Params
```elixir
def action(conn, %{"tenant_id" => tenant_id, "id" => id, "sha" => sha}) do
```

### JSON Request Body
```elixir
def create(conn, %{"tenant_id" => tenant_id} = params) do
  content = params["content"]  # from JSON body
```

### Custom Status Codes
```elixir
conn |> put_status(:created) |> json(data)      # 201
conn |> put_status(:no_content) |> send_resp(204, "")
conn |> put_status(:bad_request) |> json(%{error: "invalid"})
```

### Tenant Isolation
The auth plug validates tenant matches token. Additional checks:
```elixir
# Claims available after auth plug
claims = conn.assigns[:claims]
token_tenant = claims["tenantId"]
token_doc = claims["documentId"]
```
