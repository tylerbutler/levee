defmodule Levee.Auth.JWTTest do
  use ExUnit.Case, async: false

  alias Levee.Auth.JWT
  alias Levee.Auth.TenantSecrets

  @tenant_id "test-tenant"
  @document_id "test-doc"
  @user_id "test-user"

  setup do
    # Ensure tenant is registered for tests
    TenantSecrets.register_tenant(@tenant_id, "test-secret-key-for-testing")
    on_exit(fn -> TenantSecrets.unregister_tenant(@tenant_id) end)
    :ok
  end

  describe "sign/2" do
    test "signs a valid token" do
      claims = %{
        documentId: @document_id,
        scopes: ["doc:read", "doc:write"],
        tenantId: @tenant_id,
        user: %{id: @user_id}
      }

      assert {:ok, token} = JWT.sign(claims, @tenant_id)
      assert is_binary(token)
      assert String.contains?(token, ".")
    end

    test "returns error for unknown tenant" do
      claims = %{
        documentId: @document_id,
        scopes: ["doc:read"],
        tenantId: "unknown-tenant",
        user: %{id: @user_id}
      }

      assert {:error, {:tenant_secret_not_found, _}} = JWT.sign(claims, "unknown-tenant")
    end
  end

  describe "verify/2" do
    test "verifies a valid token" do
      {:ok, token} = JWT.generate_test_token(@tenant_id, @document_id, @user_id)

      assert {:ok, claims} = JWT.verify(token, @tenant_id)
      assert claims.documentId == @document_id
      assert claims.tenantId == @tenant_id
      assert claims.user.id == @user_id
      assert "doc:read" in claims.scopes
      assert "doc:write" in claims.scopes
    end

    test "rejects token with invalid signature" do
      {:ok, token} = JWT.generate_test_token(@tenant_id, @document_id, @user_id)

      # Tamper with the token
      tampered_token = token <> "x"

      assert {:error, :invalid_signature} = JWT.verify(tampered_token, @tenant_id)
    end

    test "rejects token for wrong tenant" do
      TenantSecrets.register_tenant("other-tenant", "other-secret")

      {:ok, token} = JWT.generate_test_token(@tenant_id, @document_id, @user_id)

      # Try to verify with wrong tenant's secret
      assert {:error, :invalid_signature} = JWT.verify(token, "other-tenant")

      TenantSecrets.unregister_tenant("other-tenant")
    end

    test "returns error for unknown tenant" do
      {:ok, token} = JWT.generate_test_token(@tenant_id, @document_id, @user_id)

      assert {:error, {:tenant_secret_not_found, _}} = JWT.verify(token, "unknown-tenant")
    end
  end

  describe "generate_test_token/4" do
    test "generates token with default scopes" do
      {:ok, token} = JWT.generate_test_token(@tenant_id, @document_id, @user_id)

      {:ok, claims} = JWT.verify(token, @tenant_id)
      assert "doc:read" in claims.scopes
      assert "doc:write" in claims.scopes
    end

    test "generates token with custom scopes" do
      {:ok, token} =
        JWT.generate_test_token(@tenant_id, @document_id, @user_id, scopes: ["doc:read"])

      {:ok, claims} = JWT.verify(token, @tenant_id)
      assert "doc:read" in claims.scopes
      refute "doc:write" in claims.scopes
    end

    test "generates token with custom expiration" do
      {:ok, token} =
        JWT.generate_test_token(@tenant_id, @document_id, @user_id, expires_in: 60)

      {:ok, claims} = JWT.verify(token, @tenant_id)
      # Should expire in about 60 seconds
      assert claims.exp - claims.iat == 60
    end
  end

  describe "generate_read_only_token/4" do
    test "generates token with only doc:read scope" do
      {:ok, token} = JWT.generate_read_only_token(@tenant_id, @document_id, @user_id)

      {:ok, claims} = JWT.verify(token, @tenant_id)
      assert claims.scopes == ["doc:read"]
    end
  end

  describe "generate_full_access_token/4" do
    test "generates token with all scopes" do
      {:ok, token} = JWT.generate_full_access_token(@tenant_id, @document_id, @user_id)

      {:ok, claims} = JWT.verify(token, @tenant_id)
      assert "doc:read" in claims.scopes
      assert "doc:write" in claims.scopes
      assert "summary:write" in claims.scopes
    end
  end

  describe "expired?/1" do
    test "returns false for valid token" do
      {:ok, token} = JWT.generate_test_token(@tenant_id, @document_id, @user_id)
      {:ok, claims} = JWT.verify(token, @tenant_id)

      refute JWT.expired?(claims)
    end

    test "returns true for expired token" do
      # Generate token that expires immediately
      {:ok, token} =
        JWT.generate_test_token(@tenant_id, @document_id, @user_id, expires_in: -1)

      {:ok, claims} = JWT.verify(token, @tenant_id)

      assert JWT.expired?(claims)
    end
  end

  describe "has_scope?/2" do
    test "returns true when scope is present" do
      {:ok, token} = JWT.generate_test_token(@tenant_id, @document_id, @user_id)
      {:ok, claims} = JWT.verify(token, @tenant_id)

      assert JWT.has_scope?(claims, "doc:read")
      assert JWT.has_scope?(claims, "doc:write")
    end

    test "returns false when scope is missing" do
      {:ok, token} =
        JWT.generate_test_token(@tenant_id, @document_id, @user_id, scopes: ["doc:read"])

      {:ok, claims} = JWT.verify(token, @tenant_id)

      assert JWT.has_scope?(claims, "doc:read")
      refute JWT.has_scope?(claims, "doc:write")
      refute JWT.has_scope?(claims, "summary:write")
    end
  end

  describe "has_read_scope?/1" do
    test "returns true when doc:read is present" do
      {:ok, token} =
        JWT.generate_test_token(@tenant_id, @document_id, @user_id, scopes: ["doc:read"])

      {:ok, claims} = JWT.verify(token, @tenant_id)

      assert JWT.has_read_scope?(claims)
    end

    test "returns false when doc:read is missing" do
      {:ok, token} =
        JWT.generate_test_token(@tenant_id, @document_id, @user_id, scopes: ["doc:write"])

      {:ok, claims} = JWT.verify(token, @tenant_id)

      refute JWT.has_read_scope?(claims)
    end
  end

  describe "has_write_scope?/1" do
    test "returns true when doc:write is present" do
      {:ok, token} =
        JWT.generate_test_token(@tenant_id, @document_id, @user_id, scopes: ["doc:write"])

      {:ok, claims} = JWT.verify(token, @tenant_id)

      assert JWT.has_write_scope?(claims)
    end

    test "returns false when doc:write is missing" do
      {:ok, token} =
        JWT.generate_test_token(@tenant_id, @document_id, @user_id, scopes: ["doc:read"])

      {:ok, claims} = JWT.verify(token, @tenant_id)

      refute JWT.has_write_scope?(claims)
    end
  end

  describe "has_summary_write_scope?/1" do
    test "returns true when summary:write is present" do
      {:ok, token} =
        JWT.generate_test_token(@tenant_id, @document_id, @user_id, scopes: ["summary:write"])

      {:ok, claims} = JWT.verify(token, @tenant_id)

      assert JWT.has_summary_write_scope?(claims)
    end

    test "returns false when summary:write is missing" do
      {:ok, token} =
        JWT.generate_test_token(@tenant_id, @document_id, @user_id,
          scopes: ["doc:read", "doc:write"]
        )

      {:ok, claims} = JWT.verify(token, @tenant_id)

      refute JWT.has_summary_write_scope?(claims)
    end
  end

  describe "verify/2 with dual secrets" do
    test "verifies token signed with secret1" do
      {:ok, tenant} = TenantSecrets.create_tenant("Dual Test")
      on_exit(fn -> TenantSecrets.unregister_tenant(tenant.id) end)

      # Sign manually with secret1
      claims = %{
        documentId: @document_id,
        scopes: ["doc:read"],
        tenantId: tenant.id,
        user: %{id: @user_id}
      }

      {:ok, token} = JWT.sign(claims, tenant.id)
      assert {:ok, _claims} = JWT.verify(token, tenant.id)
    end

    test "verifies token signed with secret2" do
      {:ok, tenant} = TenantSecrets.create_tenant("Dual Test 2")
      on_exit(fn -> TenantSecrets.unregister_tenant(tenant.id) end)

      # Sign a token directly with secret2 using JOSE
      jwk = JOSE.JWK.from_oct(tenant.secret2)
      jws = %{"alg" => "HS256"}
      now = System.system_time(:second)

      payload =
        Jason.encode!(%{
          documentId: @document_id,
          scopes: ["doc:read"],
          tenantId: tenant.id,
          user: %{id: @user_id},
          iat: now,
          exp: now + 3600,
          ver: "1.0"
        })

      {_, token} = JOSE.JWS.compact(JOSE.JWT.sign(jwk, jws, payload))

      assert {:ok, claims} = JWT.verify(token, tenant.id)
      assert claims.tenantId == tenant.id
    end

    test "rejects token signed with neither secret" do
      {:ok, tenant} = TenantSecrets.create_tenant("Dual Test 3")
      on_exit(fn -> TenantSecrets.unregister_tenant(tenant.id) end)

      # Sign with a random secret
      jwk = JOSE.JWK.from_oct("totally-wrong-secret-not-in-tenant")
      jws = %{"alg" => "HS256"}
      now = System.system_time(:second)

      payload =
        Jason.encode!(%{
          documentId: @document_id,
          scopes: ["doc:read"],
          tenantId: tenant.id,
          user: %{id: @user_id},
          iat: now,
          exp: now + 3600,
          ver: "1.0"
        })

      {_, token} = JOSE.JWS.compact(JOSE.JWT.sign(jwk, jws, payload))

      assert {:error, :invalid_signature} = JWT.verify(token, tenant.id)
    end

    test "after regenerating secret1, old secret1 tokens fail but secret2 tokens work" do
      {:ok, tenant} = TenantSecrets.create_tenant("Rotation Test")
      on_exit(fn -> TenantSecrets.unregister_tenant(tenant.id) end)

      # Sign a token with secret1 (the default for JWT.sign)
      claims = %{
        documentId: @document_id,
        scopes: ["doc:read"],
        tenantId: tenant.id,
        user: %{id: @user_id}
      }

      {:ok, old_s1_token} = JWT.sign(claims, tenant.id)

      # Sign a token with secret2 manually
      jwk2 = JOSE.JWK.from_oct(tenant.secret2)
      jws = %{"alg" => "HS256"}
      now = System.system_time(:second)

      payload =
        Jason.encode!(%{
          documentId: @document_id,
          scopes: ["doc:read"],
          tenantId: tenant.id,
          user: %{id: @user_id},
          iat: now,
          exp: now + 3600,
          ver: "1.0"
        })

      {_, s2_token} = JOSE.JWS.compact(JOSE.JWT.sign(jwk2, jws, payload))

      # Both should verify before rotation
      assert {:ok, _} = JWT.verify(old_s1_token, tenant.id)
      assert {:ok, _} = JWT.verify(s2_token, tenant.id)

      # Regenerate secret1
      {:ok, _new_secret} = TenantSecrets.regenerate_secret(tenant.id, 1)

      # Old secret1 token should now fail
      assert {:error, :invalid_signature} = JWT.verify(old_s1_token, tenant.id)

      # Secret2 token should still work
      assert {:ok, _} = JWT.verify(s2_token, tenant.id)
    end
  end
end
