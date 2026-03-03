defmodule LeveeWeb.TenantAdminControllerTest do
  use LeveeWeb.ConnCase

  alias Levee.Auth.GleamBridge
  alias Levee.Auth.TenantSecrets

  setup do
    GleamBridge.clear_session_store()

    # Clear any tenants registered at app startup (e.g. dev-tenant)
    for tenant_id <- TenantSecrets.list_tenants() do
      TenantSecrets.unregister_tenant(tenant_id)
    end

    {:ok, admin_user} =
      GleamBridge.create_user("admin@example.com", "admin_password_123", "Admin User")

    admin_user = %{admin_user | is_admin: true}
    GleamBridge.store_user(admin_user)

    admin_session = GleamBridge.create_session(admin_user.id, nil)
    GleamBridge.store_session(admin_session)

    {:ok, regular_user} =
      GleamBridge.create_user("user@example.com", "user_password_123", "Regular User")

    GleamBridge.store_user(regular_user)

    regular_session = GleamBridge.create_session(regular_user.id, nil)
    GleamBridge.store_session(regular_session)

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

    test "returns list of tenants with names", %{conn: conn, admin_session: session} do
      {:ok, t1} = TenantSecrets.create_tenant("App One")
      {:ok, t2} = TenantSecrets.create_tenant("App Two")

      conn =
        conn
        |> auth_header(session)
        |> get("/api/tenants")

      assert %{"tenants" => tenants} = json_response(conn, 200)
      ids = Enum.map(tenants, & &1["id"])
      assert t1.id in ids
      assert t2.id in ids

      app1 = Enum.find(tenants, &(&1["id"] == t1.id))
      assert app1["name"] == "App One"
      refute Map.has_key?(app1, "secret1")
      refute Map.has_key?(app1, "secret2")
    end

    test "returns 401 without authorization", %{conn: conn} do
      conn = get(conn, "/api/tenants")
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
    test "creates tenant with server-generated ID and secrets", %{
      conn: conn,
      admin_session: session
    } do
      conn =
        conn
        |> auth_header(session)
        |> put_req_header("content-type", "application/json")
        |> post("/api/tenants", %{name: "My New App"})

      assert %{"tenant" => tenant} = json_response(conn, 201)
      assert is_binary(tenant["id"])
      assert tenant["name"] == "My New App"
      assert is_binary(tenant["secret1"])
      assert is_binary(tenant["secret2"])
      assert String.length(tenant["secret1"]) == 64
      assert String.length(tenant["secret2"]) == 64
      assert TenantSecrets.tenant_exists?(tenant["id"])
    end

    test "returns 422 when name is missing", %{conn: conn, admin_session: session} do
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
        |> post("/api/tenants", %{name: "Test"})

      assert %{"error" => error} = json_response(conn, 401)
      assert error["code"] == "unauthorized"
    end

    test "returns 403 for non-admin user", %{conn: conn, regular_session: session} do
      conn =
        conn
        |> auth_header(session)
        |> put_req_header("content-type", "application/json")
        |> post("/api/tenants", %{name: "Test"})

      assert %{"error" => error} = json_response(conn, 403)
      assert error["code"] == "forbidden"
    end
  end

  describe "GET /api/tenants/:id" do
    test "returns tenant info with secrets", %{conn: conn, admin_session: session} do
      {:ok, created} = TenantSecrets.create_tenant("My App")

      conn =
        conn
        |> auth_header(session)
        |> get("/api/tenants/#{created.id}")

      assert %{"tenant" => tenant} = json_response(conn, 200)
      assert tenant["id"] == created.id
      assert tenant["name"] == "My App"
      assert tenant["secret1"] == created.secret1
      assert tenant["secret2"] == created.secret2
    end

    test "returns 404 when tenant does not exist", %{conn: conn, admin_session: session} do
      conn =
        conn
        |> auth_header(session)
        |> get("/api/tenants/nonexistent")

      assert %{"error" => error} = json_response(conn, 404)
      assert error["code"] == "not_found"
    end
  end

  describe "POST /api/tenants/:id/secrets/:slot" do
    test "regenerates secret1", %{conn: conn, admin_session: session} do
      {:ok, created} = TenantSecrets.create_tenant("Regen Test")

      conn =
        conn
        |> auth_header(session)
        |> post("/api/tenants/#{created.id}/secrets/1")

      assert %{"secret" => new_secret} = json_response(conn, 200)
      assert is_binary(new_secret)
      assert String.length(new_secret) == 64
      assert new_secret != created.secret1

      {:ok, secrets} = TenantSecrets.get_secrets(created.id)
      assert secrets.secret1 == new_secret
      assert secrets.secret2 == created.secret2
    end

    test "regenerates secret2", %{conn: conn, admin_session: session} do
      {:ok, created} = TenantSecrets.create_tenant("Regen Test 2")

      conn =
        conn
        |> auth_header(session)
        |> post("/api/tenants/#{created.id}/secrets/2")

      assert %{"secret" => new_secret} = json_response(conn, 200)
      assert new_secret != created.secret2
    end

    test "returns 400 for invalid slot", %{conn: conn, admin_session: session} do
      {:ok, created} = TenantSecrets.create_tenant("Regen Test 3")

      conn =
        conn
        |> auth_header(session)
        |> post("/api/tenants/#{created.id}/secrets/3")

      assert %{"error" => error} = json_response(conn, 400)
      assert error["code"] == "invalid_slot"
    end

    test "returns 404 for non-existent tenant", %{conn: conn, admin_session: session} do
      conn =
        conn
        |> auth_header(session)
        |> post("/api/tenants/nonexistent/secrets/1")

      assert %{"error" => error} = json_response(conn, 404)
      assert error["code"] == "not_found"
    end

    test "returns 401 without authorization", %{conn: conn} do
      conn = post(conn, "/api/tenants/some-id/secrets/1")
      assert %{"error" => error} = json_response(conn, 401)
      assert error["code"] == "unauthorized"
    end

    test "returns 403 for non-admin user", %{conn: conn, regular_session: session} do
      conn =
        conn
        |> auth_header(session)
        |> post("/api/tenants/some-id/secrets/1")

      assert %{"error" => error} = json_response(conn, 403)
      assert error["code"] == "forbidden"
    end
  end

  describe "DELETE /api/tenants/:id" do
    test "deletes an existing tenant", %{conn: conn, admin_session: session} do
      {:ok, tenant} = TenantSecrets.create_tenant("Delete Me")
      assert TenantSecrets.tenant_exists?(tenant.id)

      conn =
        conn
        |> auth_header(session)
        |> delete("/api/tenants/#{tenant.id}")

      assert %{"message" => _} = json_response(conn, 200)
      refute TenantSecrets.tenant_exists?(tenant.id)
    end

    test "returns 404 when tenant does not exist", %{conn: conn, admin_session: session} do
      conn =
        conn
        |> auth_header(session)
        |> delete("/api/tenants/nonexistent")

      assert %{"error" => error} = json_response(conn, 404)
      assert error["code"] == "not_found"
    end
  end
end
