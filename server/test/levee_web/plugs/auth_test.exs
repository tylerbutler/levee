defmodule LeveeWeb.Plugs.AuthTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Levee.Auth.JWT
  alias Levee.Auth.TenantSecrets
  alias LeveeWeb.Plugs.Auth

  @tenant_id "auth-test-tenant"
  @document_id "auth-test-doc"
  @user_id "auth-test-user"

  setup do
    TenantSecrets.register_tenant(@tenant_id, "test-secret-for-auth-tests")
    on_exit(fn -> TenantSecrets.unregister_tenant(@tenant_id) end)
    :ok
  end

  describe "extract_token/1" do
    test "extracts Bearer token from Authorization header" do
      conn =
        conn(:get, "/")
        |> put_req_header("authorization", "Bearer test-token")

      assert {:ok, "test-token"} = Auth.extract_token(conn)
    end

    test "trims whitespace from token" do
      conn =
        conn(:get, "/")
        |> put_req_header("authorization", "Bearer  test-token  ")

      assert {:ok, "test-token"} = Auth.extract_token(conn)
    end

    test "returns error when header is missing" do
      conn = conn(:get, "/")

      assert {:error, :missing_token} = Auth.extract_token(conn)
    end

    test "returns error for non-Bearer authorization" do
      conn =
        conn(:get, "/")
        |> put_req_header("authorization", "Basic dXNlcjpwYXNz")

      assert {:error, :invalid_auth_header} = Auth.extract_token(conn)
    end
  end

  describe "call/2 - token validation" do
    test "authenticates valid token" do
      {:ok, token} = JWT.generate_test_token(@tenant_id, @document_id, @user_id)

      opts = Auth.init(scopes: [])

      conn =
        conn(:get, "/documents/#{@tenant_id}/#{@document_id}")
        |> put_req_header("authorization", "Bearer #{token}")
        |> Map.put(:params, %{"tenant_id" => @tenant_id, "id" => @document_id})
        |> Map.put(:path_params, %{"tenant_id" => @tenant_id, "id" => @document_id})
        |> Auth.call(opts)

      refute conn.halted
      assert conn.assigns.authenticated == true
      assert conn.assigns.claims.tenantId == @tenant_id
      assert conn.assigns.claims.documentId == @document_id
    end

    test "rejects missing token" do
      opts = Auth.init(scopes: [])

      conn =
        conn(:get, "/documents/#{@tenant_id}/#{@document_id}")
        |> Map.put(:params, %{"tenant_id" => @tenant_id, "id" => @document_id})
        |> Map.put(:path_params, %{"tenant_id" => @tenant_id, "id" => @document_id})
        |> Auth.call(opts)

      assert conn.halted
      assert conn.status == 401
      assert Jason.decode!(conn.resp_body)["error"] =~ "Missing Authorization"
    end

    test "rejects invalid signature" do
      {:ok, token} = JWT.generate_test_token(@tenant_id, @document_id, @user_id)
      tampered_token = token <> "x"

      opts = Auth.init(scopes: [])

      conn =
        conn(:get, "/documents/#{@tenant_id}/#{@document_id}")
        |> put_req_header("authorization", "Bearer #{tampered_token}")
        |> Map.put(:params, %{"tenant_id" => @tenant_id, "id" => @document_id})
        |> Map.put(:path_params, %{"tenant_id" => @tenant_id, "id" => @document_id})
        |> Auth.call(opts)

      assert conn.halted
      assert conn.status == 401
      assert Jason.decode!(conn.resp_body)["error"] =~ "Invalid token"
    end

    test "rejects expired token" do
      {:ok, token} =
        JWT.generate_test_token(@tenant_id, @document_id, @user_id, expires_in: -1)

      opts = Auth.init(scopes: [])

      conn =
        conn(:get, "/documents/#{@tenant_id}/#{@document_id}")
        |> put_req_header("authorization", "Bearer #{token}")
        |> Map.put(:params, %{"tenant_id" => @tenant_id, "id" => @document_id})
        |> Map.put(:path_params, %{"tenant_id" => @tenant_id, "id" => @document_id})
        |> Auth.call(opts)

      assert conn.halted
      assert conn.status == 401
      assert Jason.decode!(conn.resp_body)["error"] =~ "expired"
    end

    test "rejects unknown tenant" do
      {:ok, token} = JWT.generate_test_token(@tenant_id, @document_id, @user_id)

      opts = Auth.init(scopes: [])

      conn =
        conn(:get, "/documents/unknown-tenant/#{@document_id}")
        |> put_req_header("authorization", "Bearer #{token}")
        |> Map.put(:params, %{"tenant_id" => "unknown-tenant", "id" => @document_id})
        |> Map.put(:path_params, %{"tenant_id" => "unknown-tenant", "id" => @document_id})
        |> Auth.call(opts)

      assert conn.halted
      assert conn.status == 401
      assert Jason.decode!(conn.resp_body)["error"] =~ "tenant"
    end
  end

  describe "call/2 - tenant validation" do
    test "rejects token for different tenant" do
      # Create token for different tenant
      TenantSecrets.register_tenant("other-tenant", "other-secret")
      {:ok, token} = JWT.generate_test_token("other-tenant", @document_id, @user_id)
      TenantSecrets.unregister_tenant("other-tenant")

      opts = Auth.init(scopes: [])

      conn =
        conn(:get, "/documents/#{@tenant_id}/#{@document_id}")
        |> put_req_header("authorization", "Bearer #{token}")
        |> Map.put(:params, %{"tenant_id" => @tenant_id, "id" => @document_id})
        |> Map.put(:path_params, %{"tenant_id" => @tenant_id, "id" => @document_id})
        |> Auth.call(opts)

      # Will fail signature validation since we're using different secret
      assert conn.halted
      assert conn.status == 401
    end
  end

  describe "call/2 - document validation" do
    test "rejects token for different document" do
      {:ok, token} = JWT.generate_test_token(@tenant_id, "other-doc", @user_id)

      opts = Auth.init(scopes: [])

      conn =
        conn(:get, "/documents/#{@tenant_id}/#{@document_id}")
        |> put_req_header("authorization", "Bearer #{token}")
        |> Map.put(:params, %{"tenant_id" => @tenant_id, "id" => @document_id})
        |> Map.put(:path_params, %{"tenant_id" => @tenant_id, "id" => @document_id})
        |> Auth.call(opts)

      assert conn.halted
      assert conn.status == 403
      assert Jason.decode!(conn.resp_body)["error"] =~ "document"
    end

    test "skips document validation when disabled" do
      {:ok, token} = JWT.generate_test_token(@tenant_id, "other-doc", @user_id)

      opts = Auth.init(scopes: [], validate_document: false)

      conn =
        conn(:get, "/documents/#{@tenant_id}/#{@document_id}")
        |> put_req_header("authorization", "Bearer #{token}")
        |> Map.put(:params, %{"tenant_id" => @tenant_id, "id" => @document_id})
        |> Map.put(:path_params, %{"tenant_id" => @tenant_id, "id" => @document_id})
        |> Auth.call(opts)

      refute conn.halted
    end

    test "skips document validation when document param not in route" do
      {:ok, token} = JWT.generate_test_token(@tenant_id, @document_id, @user_id)

      opts = Auth.init(scopes: [])

      conn =
        conn(:get, "/documents/#{@tenant_id}")
        |> put_req_header("authorization", "Bearer #{token}")
        |> Map.put(:params, %{"tenant_id" => @tenant_id})
        |> Map.put(:path_params, %{"tenant_id" => @tenant_id})
        |> Auth.call(opts)

      refute conn.halted
    end
  end

  describe "call/2 - scope validation" do
    test "allows request when token has required scope" do
      {:ok, token} =
        JWT.generate_test_token(@tenant_id, @document_id, @user_id,
          scopes: ["doc:read", "doc:write"]
        )

      opts = Auth.init(scopes: ["doc:read"])

      conn =
        conn(:get, "/documents/#{@tenant_id}/#{@document_id}")
        |> put_req_header("authorization", "Bearer #{token}")
        |> Map.put(:params, %{"tenant_id" => @tenant_id, "id" => @document_id})
        |> Map.put(:path_params, %{"tenant_id" => @tenant_id, "id" => @document_id})
        |> Auth.call(opts)

      refute conn.halted
    end

    test "allows request when token has all required scopes" do
      {:ok, token} =
        JWT.generate_test_token(@tenant_id, @document_id, @user_id,
          scopes: ["doc:read", "doc:write", "summary:write"]
        )

      opts = Auth.init(scopes: ["doc:read", "doc:write"])

      conn =
        conn(:get, "/documents/#{@tenant_id}/#{@document_id}")
        |> put_req_header("authorization", "Bearer #{token}")
        |> Map.put(:params, %{"tenant_id" => @tenant_id, "id" => @document_id})
        |> Map.put(:path_params, %{"tenant_id" => @tenant_id, "id" => @document_id})
        |> Auth.call(opts)

      refute conn.halted
    end

    test "rejects when token missing required scope" do
      {:ok, token} =
        JWT.generate_test_token(@tenant_id, @document_id, @user_id, scopes: ["doc:read"])

      opts = Auth.init(scopes: ["doc:read", "doc:write"])

      conn =
        conn(:get, "/documents/#{@tenant_id}/#{@document_id}")
        |> put_req_header("authorization", "Bearer #{token}")
        |> Map.put(:params, %{"tenant_id" => @tenant_id, "id" => @document_id})
        |> Map.put(:path_params, %{"tenant_id" => @tenant_id, "id" => @document_id})
        |> Auth.call(opts)

      assert conn.halted
      assert conn.status == 403
      assert Jason.decode!(conn.resp_body)["error"] =~ "scope"
      assert Jason.decode!(conn.resp_body)["error"] =~ "doc:write"
    end
  end

  describe "init/1" do
    test "sets default options" do
      opts = Auth.init([])

      assert opts.scopes == []
      assert opts.tenant_param == "tenant_id"
      assert opts.document_param == "id"
      assert opts.validate_document == true
    end

    test "accepts custom options" do
      opts =
        Auth.init(
          scopes: ["doc:read"],
          tenant_param: "tenantId",
          document_param: "docId",
          validate_document: false
        )

      assert opts.scopes == ["doc:read"]
      assert opts.tenant_param == "tenantId"
      assert opts.document_param == "docId"
      assert opts.validate_document == false
    end
  end
end
