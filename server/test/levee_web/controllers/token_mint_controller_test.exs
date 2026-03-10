defmodule LeveeWeb.TokenMintControllerTest do
  use LeveeWeb.ConnCase

  alias Levee.Auth.GleamBridge
  alias Levee.Auth.TenantSecrets
  alias Levee.Auth.JWT

  @tenant_id "test-mint-tenant"
  @tenant_secret "test-mint-secret-key-for-signing"

  setup do
    GleamBridge.clear_session_store()

    # Register a tenant with a known secret
    TenantSecrets.register_tenant(@tenant_id, @tenant_secret)

    # Create and store a user
    {:ok, user} =
      GleamBridge.create_user("mint@example.com", "password123", "Mint User")

    GleamBridge.store_user(user)

    # Create and store a session
    session = GleamBridge.create_session(user.id, nil)
    GleamBridge.store_session(session)

    on_exit(fn -> TenantSecrets.unregister_tenant(@tenant_id) end)

    {:ok, user: user, session: session}
  end

  describe "POST /api/tenants/:tenant_id/token-mint" do
    test "returns JWT for valid session and tenant", %{conn: conn, session: session, user: user} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer #{session.id}")
        |> post("/api/tenants/#{@tenant_id}/token-mint", %{documentId: "doc-123"})

      assert %{"jwt" => jwt, "expiresIn" => 3600} = json_response(conn, 200)
      assert is_binary(jwt)

      # Verify the JWT can be decoded and has correct claims
      {:ok, claims} = JWT.verify(jwt, @tenant_id)
      assert claims.documentId == "doc-123"
      assert claims.tenantId == @tenant_id
      assert claims.user.id == user.id
      assert "doc:read" in claims.scopes
      assert "doc:write" in claims.scopes
      assert "summary:write" in claims.scopes
    end

    test "returns 401 without authorization header", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/tenants/#{@tenant_id}/token-mint", %{documentId: "doc-123"})

      assert %{"error" => _} = json_response(conn, 401)
    end

    test "returns 401 with invalid session token", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer invalid-session-id")
        |> post("/api/tenants/#{@tenant_id}/token-mint", %{documentId: "doc-123"})

      assert %{"error" => _} = json_response(conn, 401)
    end

    test "returns 400 when documentId is missing", %{conn: conn, session: session} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer #{session.id}")
        |> post("/api/tenants/#{@tenant_id}/token-mint", %{})

      assert %{"error" => error} = json_response(conn, 400)
      assert error =~ "documentId"
    end

    test "returns 404 for unknown tenant", %{conn: conn, session: session} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer #{session.id}")
        |> post("/api/tenants/nonexistent-tenant/token-mint", %{documentId: "doc-123"})

      assert %{"error" => _} = json_response(conn, 404)
    end

    test "returned JWT contains correct expiration", %{conn: conn, session: session} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer #{session.id}")
        |> post("/api/tenants/#{@tenant_id}/token-mint", %{documentId: "doc-456"})

      assert %{"jwt" => jwt} = json_response(conn, 200)

      {:ok, claims} = JWT.verify(jwt, @tenant_id)
      assert claims.exp - claims.iat == 3600
      assert claims.ver == "1.0"
    end
  end
end
