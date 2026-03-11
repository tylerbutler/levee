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

    # Create and store an owner membership for the user in the test tenant
    membership = GleamBridge.create_membership(user.id, @tenant_id, :owner)
    GleamBridge.store_membership(membership)

    on_exit(fn -> TenantSecrets.unregister_tenant(@tenant_id) end)

    {:ok, user: user, session: session, membership: membership}
  end

  describe "POST /api/tenants/:tenant_id/token-mint" do
    test "returns JWT for valid session and tenant member", %{
      conn: conn,
      session: session,
      user: user
    } do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer #{session.id}")
        |> post("/api/tenants/#{@tenant_id}/token-mint", %{documentId: "doc-123"})

      assert %{"jwt" => jwt, "expiresIn" => 3600, "user" => resp_user} = json_response(conn, 200)
      assert is_binary(jwt)
      assert resp_user["id"] == user.id
      assert resp_user["name"] == "Mint User"

      # Verify the JWT can be decoded and has correct claims
      {:ok, claims} = JWT.verify(jwt, @tenant_id)
      assert claims.documentId == "doc-123"
      assert claims.tenantId == @tenant_id
      assert claims.user.id == user.id
      assert "doc:read" in claims.scopes
      assert "doc:write" in claims.scopes
      assert "summary:read" in claims.scopes
      assert "summary:write" in claims.scopes
    end

    test "returns 403 when user is not a member of the tenant", %{conn: conn} do
      # Create a different user with no membership
      {:ok, other_user} =
        GleamBridge.create_user("outsider@example.com", "password123", "Outsider")

      GleamBridge.store_user(other_user)
      other_session = GleamBridge.create_session(other_user.id, nil)
      GleamBridge.store_session(other_session)

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer #{other_session.id}")
        |> post("/api/tenants/#{@tenant_id}/token-mint", %{documentId: "doc-123"})

      assert %{"error" => error} = json_response(conn, 403)
      assert error =~ "member"
    end

    test "owner role gets full access scopes", %{conn: conn, session: session} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer #{session.id}")
        |> post("/api/tenants/#{@tenant_id}/token-mint", %{documentId: "doc-123"})

      assert %{"jwt" => jwt} = json_response(conn, 200)
      {:ok, claims} = JWT.verify(jwt, @tenant_id)
      assert "doc:read" in claims.scopes
      assert "doc:write" in claims.scopes
      assert "summary:read" in claims.scopes
      assert "summary:write" in claims.scopes
    end

    test "member role gets read-write scopes only", %{conn: conn} do
      {:ok, member_user} =
        GleamBridge.create_user("member@example.com", "password123", "Member User")

      GleamBridge.store_user(member_user)
      member_session = GleamBridge.create_session(member_user.id, nil)
      GleamBridge.store_session(member_session)

      membership = GleamBridge.create_membership(member_user.id, @tenant_id, :member)
      GleamBridge.store_membership(membership)

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer #{member_session.id}")
        |> post("/api/tenants/#{@tenant_id}/token-mint", %{documentId: "doc-123"})

      assert %{"jwt" => jwt} = json_response(conn, 200)
      {:ok, claims} = JWT.verify(jwt, @tenant_id)
      assert "doc:read" in claims.scopes
      assert "doc:write" in claims.scopes
      refute "summary:read" in claims.scopes
      refute "summary:write" in claims.scopes
    end

    test "viewer role gets read-only scopes", %{conn: conn} do
      {:ok, viewer_user} =
        GleamBridge.create_user("viewer@example.com", "password123", "Viewer User")

      GleamBridge.store_user(viewer_user)
      viewer_session = GleamBridge.create_session(viewer_user.id, nil)
      GleamBridge.store_session(viewer_session)

      membership = GleamBridge.create_membership(viewer_user.id, @tenant_id, :viewer)
      GleamBridge.store_membership(membership)

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer #{viewer_session.id}")
        |> post("/api/tenants/#{@tenant_id}/token-mint", %{documentId: "doc-123"})

      assert %{"jwt" => jwt} = json_response(conn, 200)
      {:ok, claims} = JWT.verify(jwt, @tenant_id)
      assert "doc:read" in claims.scopes
      refute "doc:write" in claims.scopes
      refute "summary:read" in claims.scopes
      refute "summary:write" in claims.scopes
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

    test "returns 404 for unknown tenant", %{conn: conn, session: session, user: user} do
      # Create membership for the nonexistent tenant so we get past the membership check
      # but since there's no tenant secret registered, JWT signing should return 404
      membership = GleamBridge.create_membership(user.id, "nonexistent-tenant", :owner)
      GleamBridge.store_membership(membership)

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
