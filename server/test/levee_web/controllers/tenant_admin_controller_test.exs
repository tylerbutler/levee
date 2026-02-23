defmodule LeveeWeb.TenantAdminControllerTest do
  use LeveeWeb.ConnCase

  alias Levee.Auth.GleamBridge
  alias Levee.Auth.SessionStore
  alias Levee.Auth.TenantSecrets

  setup do
    SessionStore.clear()

    # Create an admin user
    {:ok, admin_user} =
      GleamBridge.create_user("admin@example.com", "admin_password_123", "Admin User")

    admin_user = %{admin_user | is_admin: true}
    SessionStore.store_user(admin_user)

    admin_session = GleamBridge.create_session(admin_user.id, nil)
    SessionStore.store_session(admin_session)

    # Create a non-admin user
    {:ok, regular_user} =
      GleamBridge.create_user("user@example.com", "user_password_123", "Regular User")

    SessionStore.store_user(regular_user)

    regular_session = GleamBridge.create_session(regular_user.id, nil)
    SessionStore.store_session(regular_session)

    # Clean up any test tenants on exit
    on_exit(fn ->
      for tenant_id <- TenantSecrets.list_tenants() do
        TenantSecrets.unregister_tenant(tenant_id)
      end
    end)

    {:ok,
     admin_user: admin_user,
     admin_session: admin_session,
     regular_user: regular_user,
     regular_session: regular_session}
  end

  defp auth_header(conn, session) do
    put_req_header(conn, "authorization", "Bearer #{session.id}")
  end

  describe "GET /api/tenants" do
    test "returns empty list when no tenants exist", %{conn: conn, admin_session: session} do
      conn =
        conn
        |> auth_header(session)
        |> get("/api/tenants")

      assert %{"tenants" => []} = json_response(conn, 200)
    end

    test "returns list of tenants", %{conn: conn, admin_session: session} do
      TenantSecrets.register_tenant("tenant-a", "secret-a")
      TenantSecrets.register_tenant("tenant-b", "secret-b")

      conn =
        conn
        |> auth_header(session)
        |> get("/api/tenants")

      assert %{"tenants" => tenants} = json_response(conn, 200)
      tenant_ids = Enum.map(tenants, & &1["id"])
      assert "tenant-a" in tenant_ids
      assert "tenant-b" in tenant_ids
    end

    test "returns 401 without authorization", %{conn: conn} do
      conn = get(conn, "/api/tenants")

      assert %{"error" => error} = json_response(conn, 401)
      assert error["code"] == "unauthorized"
    end

    test "returns 401 with invalid session", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer invalid_session_id")
        |> get("/api/tenants")

      assert %{"error" => error} = json_response(conn, 401)
      assert error["code"] == "unauthorized"
    end

    test "returns 403 for non-admin user", %{conn: conn, regular_session: session} do
      conn =
        conn
        |> auth_header(session)
        |> get("/api/tenants")

      assert %{"error" => error} = json_response(conn, 403)
      assert error["code"] == "forbidden"
    end
  end

  describe "POST /api/tenants" do
    test "creates a new tenant", %{conn: conn, admin_session: session} do
      conn =
        conn
        |> auth_header(session)
        |> put_req_header("content-type", "application/json")
        |> post("/api/tenants", %{id: "new-tenant", secret: "new-secret-key"})

      assert %{"tenant" => tenant, "message" => message} = json_response(conn, 201)
      assert tenant["id"] == "new-tenant"
      assert message == "Tenant registered"
      assert TenantSecrets.tenant_exists?("new-tenant")
    end

    test "returns 409 for duplicate tenant", %{conn: conn, admin_session: session} do
      TenantSecrets.register_tenant("existing-tenant", "some-secret")

      conn =
        conn
        |> auth_header(session)
        |> put_req_header("content-type", "application/json")
        |> post("/api/tenants", %{id: "existing-tenant", secret: "another-secret"})

      assert %{"error" => error} = json_response(conn, 409)
      assert error["code"] == "tenant_exists"
    end

    test "returns 422 when missing fields", %{conn: conn, admin_session: session} do
      conn =
        conn
        |> auth_header(session)
        |> put_req_header("content-type", "application/json")
        |> post("/api/tenants", %{id: "no-secret-tenant"})

      assert %{"error" => error} = json_response(conn, 422)
      assert error["code"] == "missing_fields"
    end

    test "returns 422 when body is empty", %{conn: conn, admin_session: session} do
      conn =
        conn
        |> auth_header(session)
        |> put_req_header("content-type", "application/json")
        |> post("/api/tenants", %{})

      assert %{"error" => error} = json_response(conn, 422)
      assert error["code"] == "missing_fields"
    end

    test "returns 401 without authorization", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/tenants", %{id: "tenant", secret: "secret"})

      assert %{"error" => error} = json_response(conn, 401)
      assert error["code"] == "unauthorized"
    end

    test "returns 403 for non-admin user", %{conn: conn, regular_session: session} do
      conn =
        conn
        |> auth_header(session)
        |> put_req_header("content-type", "application/json")
        |> post("/api/tenants", %{id: "tenant", secret: "secret"})

      assert %{"error" => error} = json_response(conn, 403)
      assert error["code"] == "forbidden"
    end
  end

  describe "GET /api/tenants/:id" do
    test "returns tenant when it exists", %{conn: conn, admin_session: session} do
      TenantSecrets.register_tenant("my-tenant", "my-secret")

      conn =
        conn
        |> auth_header(session)
        |> get("/api/tenants/my-tenant")

      assert %{"tenant" => tenant} = json_response(conn, 200)
      assert tenant["id"] == "my-tenant"
    end

    test "returns 404 when tenant does not exist", %{conn: conn, admin_session: session} do
      conn =
        conn
        |> auth_header(session)
        |> get("/api/tenants/nonexistent")

      assert %{"error" => error} = json_response(conn, 404)
      assert error["code"] == "not_found"
    end

    test "returns 401 without authorization", %{conn: conn} do
      conn = get(conn, "/api/tenants/some-tenant")

      assert %{"error" => error} = json_response(conn, 401)
      assert error["code"] == "unauthorized"
    end

    test "returns 403 for non-admin user", %{conn: conn, regular_session: session} do
      conn =
        conn
        |> auth_header(session)
        |> get("/api/tenants/some-tenant")

      assert %{"error" => error} = json_response(conn, 403)
      assert error["code"] == "forbidden"
    end
  end

  describe "PUT /api/tenants/:id" do
    test "updates tenant secret", %{conn: conn, admin_session: session} do
      TenantSecrets.register_tenant("update-tenant", "old-secret")

      conn =
        conn
        |> auth_header(session)
        |> put_req_header("content-type", "application/json")
        |> put("/api/tenants/update-tenant", %{secret: "new-secret"})

      assert %{"tenant" => tenant, "message" => message} = json_response(conn, 200)
      assert tenant["id"] == "update-tenant"
      assert message == "Tenant secret updated"
      assert {:ok, "new-secret"} = TenantSecrets.get_secret("update-tenant")
    end

    test "returns 404 when tenant does not exist", %{conn: conn, admin_session: session} do
      conn =
        conn
        |> auth_header(session)
        |> put_req_header("content-type", "application/json")
        |> put("/api/tenants/nonexistent", %{secret: "new-secret"})

      assert %{"error" => error} = json_response(conn, 404)
      assert error["code"] == "not_found"
    end

    test "returns 422 when secret is missing", %{conn: conn, admin_session: session} do
      TenantSecrets.register_tenant("update-tenant-2", "some-secret")

      conn =
        conn
        |> auth_header(session)
        |> put_req_header("content-type", "application/json")
        |> put("/api/tenants/update-tenant-2", %{})

      assert %{"error" => error} = json_response(conn, 422)
      assert error["code"] == "missing_fields"
    end

    test "returns 401 without authorization", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put("/api/tenants/some-tenant", %{secret: "secret"})

      assert %{"error" => error} = json_response(conn, 401)
      assert error["code"] == "unauthorized"
    end

    test "returns 403 for non-admin user", %{conn: conn, regular_session: session} do
      conn =
        conn
        |> auth_header(session)
        |> put_req_header("content-type", "application/json")
        |> put("/api/tenants/some-tenant", %{secret: "secret"})

      assert %{"error" => error} = json_response(conn, 403)
      assert error["code"] == "forbidden"
    end
  end

  describe "DELETE /api/tenants/:id" do
    test "deletes an existing tenant", %{conn: conn, admin_session: session} do
      TenantSecrets.register_tenant("delete-tenant", "delete-secret")
      assert TenantSecrets.tenant_exists?("delete-tenant")

      conn =
        conn
        |> auth_header(session)
        |> delete("/api/tenants/delete-tenant")

      assert %{"message" => _message} = json_response(conn, 200)
      refute TenantSecrets.tenant_exists?("delete-tenant")
    end

    test "returns 404 when tenant does not exist", %{conn: conn, admin_session: session} do
      conn =
        conn
        |> auth_header(session)
        |> delete("/api/tenants/nonexistent")

      assert %{"error" => error} = json_response(conn, 404)
      assert error["code"] == "not_found"
    end

    test "returns 401 without authorization", %{conn: conn} do
      conn = delete(conn, "/api/tenants/some-tenant")

      assert %{"error" => error} = json_response(conn, 401)
      assert error["code"] == "unauthorized"
    end

    test "returns 403 for non-admin user", %{conn: conn, regular_session: session} do
      conn =
        conn
        |> auth_header(session)
        |> delete("/api/tenants/some-tenant")

      assert %{"error" => error} = json_response(conn, 403)
      assert error["code"] == "forbidden"
    end
  end
end
