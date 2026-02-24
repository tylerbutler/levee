defmodule Levee.Auth.TenantSecretsTest do
  use ExUnit.Case, async: false

  alias Levee.Auth.TenantSecrets

  setup do
    # Clean up all test tenants
    for id <- TenantSecrets.list_tenants() do
      TenantSecrets.unregister_tenant(id)
    end

    on_exit(fn ->
      for id <- TenantSecrets.list_tenants() do
        TenantSecrets.unregister_tenant(id)
      end
    end)

    :ok
  end

  describe "create_tenant/1" do
    test "creates a tenant with server-generated ID and secrets" do
      {:ok, tenant} = TenantSecrets.create_tenant("My App")

      assert is_binary(tenant.id)
      assert tenant.name == "My App"
      assert is_binary(tenant.secret1)
      assert is_binary(tenant.secret2)
      assert String.length(tenant.secret1) == 64
      assert String.length(tenant.secret2) == 64
      assert tenant.secret1 != tenant.secret2
      assert TenantSecrets.tenant_exists?(tenant.id)
    end

    test "generates hyphenated adjective-color-animal ID" do
      {:ok, tenant} = TenantSecrets.create_tenant("Test")

      parts = String.split(tenant.id, "-")
      assert length(parts) == 3
    end

    test "generates unique IDs for different tenants" do
      {:ok, t1} = TenantSecrets.create_tenant("App 1")
      {:ok, t2} = TenantSecrets.create_tenant("App 2")

      assert t1.id != t2.id
    end
  end

  describe "get_tenant/1" do
    test "returns tenant info without secrets" do
      {:ok, created} = TenantSecrets.create_tenant("My App")

      assert {:ok, tenant} = TenantSecrets.get_tenant(created.id)
      assert tenant.id == created.id
      assert tenant.name == "My App"
      refute Map.has_key?(tenant, :secret1)
      refute Map.has_key?(tenant, :secret2)
    end

    test "returns error for non-existent tenant" do
      assert {:error, :tenant_not_found} = TenantSecrets.get_tenant("nonexistent")
    end
  end

  describe "get_secrets/1" do
    test "returns both secrets for a tenant" do
      {:ok, created} = TenantSecrets.create_tenant("My App")

      assert {:ok, %{secret1: s1, secret2: s2}} = TenantSecrets.get_secrets(created.id)
      assert s1 == created.secret1
      assert s2 == created.secret2
    end

    test "returns error for non-existent tenant" do
      assert {:error, :tenant_not_found} = TenantSecrets.get_secrets("nonexistent")
    end
  end

  describe "regenerate_secret/2" do
    test "regenerates secret1" do
      {:ok, created} = TenantSecrets.create_tenant("My App")
      old_secret1 = created.secret1

      {:ok, new_secret} = TenantSecrets.regenerate_secret(created.id, 1)

      assert new_secret != old_secret1
      assert String.length(new_secret) == 64

      {:ok, secrets} = TenantSecrets.get_secrets(created.id)
      assert secrets.secret1 == new_secret
      assert secrets.secret2 == created.secret2
    end

    test "regenerates secret2" do
      {:ok, created} = TenantSecrets.create_tenant("My App")
      old_secret2 = created.secret2

      {:ok, new_secret} = TenantSecrets.regenerate_secret(created.id, 2)

      assert new_secret != old_secret2

      {:ok, secrets} = TenantSecrets.get_secrets(created.id)
      assert secrets.secret1 == created.secret1
      assert secrets.secret2 == new_secret
    end

    test "returns error for invalid slot" do
      {:ok, created} = TenantSecrets.create_tenant("My App")

      assert {:error, :invalid_slot} = TenantSecrets.regenerate_secret(created.id, 3)
    end

    test "returns error for non-existent tenant" do
      assert {:error, :tenant_not_found} = TenantSecrets.regenerate_secret("nonexistent", 1)
    end
  end

  describe "unregister_tenant/1" do
    test "removes a tenant" do
      {:ok, tenant} = TenantSecrets.create_tenant("My App")
      :ok = TenantSecrets.unregister_tenant(tenant.id)

      refute TenantSecrets.tenant_exists?(tenant.id)
    end

    test "succeeds for non-existent tenant" do
      :ok = TenantSecrets.unregister_tenant("non-existent")
    end
  end

  describe "list_tenants/0" do
    test "returns list of tenant IDs" do
      {:ok, t1} = TenantSecrets.create_tenant("App 1")
      {:ok, t2} = TenantSecrets.create_tenant("App 2")

      tenants = TenantSecrets.list_tenants()
      assert t1.id in tenants
      assert t2.id in tenants
    end
  end

  describe "list_tenants_with_names/0" do
    test "returns list of {id, name} maps" do
      {:ok, t1} = TenantSecrets.create_tenant("App 1")
      {:ok, t2} = TenantSecrets.create_tenant("App 2")

      tenants = TenantSecrets.list_tenants_with_names()
      ids = Enum.map(tenants, & &1.id)
      assert t1.id in ids
      assert t2.id in ids

      app1 = Enum.find(tenants, &(&1.id == t1.id))
      assert app1.name == "App 1"
    end
  end

  describe "generate_secret/0" do
    test "returns 64-character hex string" do
      secret = TenantSecrets.generate_secret()

      assert String.length(secret) == 64
      assert Regex.match?(~r/^[0-9a-f]{64}$/, secret)
    end

    test "generates unique values" do
      s1 = TenantSecrets.generate_secret()
      s2 = TenantSecrets.generate_secret()

      assert s1 != s2
    end
  end

  describe "backward compatibility" do
    test "register_tenant/2 still works for existing callers" do
      :ok = TenantSecrets.register_tenant("legacy-id", "legacy-secret")

      assert TenantSecrets.tenant_exists?("legacy-id")

      assert {:ok, %{secret1: "legacy-secret", secret2: _}} =
               TenantSecrets.get_secrets("legacy-id")
    end

    test "get_secret/1 returns secret1 for backward compat" do
      :ok = TenantSecrets.register_tenant("legacy-id", "legacy-secret")

      assert {:ok, "legacy-secret"} = TenantSecrets.get_secret("legacy-id")
    end

    test "register_dev_tenant works" do
      :ok = TenantSecrets.register_dev_tenant("dev-test")

      assert TenantSecrets.tenant_exists?("dev-test")
    end
  end
end
