defmodule FluidServer.Auth.TenantSecretsTest do
  use ExUnit.Case, async: false

  alias FluidServer.Auth.TenantSecrets

  @tenant_id "secrets-test-tenant"
  @secret "test-secret-key"

  setup do
    # Clean up any existing test tenant
    TenantSecrets.unregister_tenant(@tenant_id)
    on_exit(fn -> TenantSecrets.unregister_tenant(@tenant_id) end)
    :ok
  end

  describe "register_tenant/2" do
    test "registers a new tenant" do
      :ok = TenantSecrets.register_tenant(@tenant_id, @secret)

      assert TenantSecrets.tenant_exists?(@tenant_id)
    end

    test "overwrites existing tenant" do
      :ok = TenantSecrets.register_tenant(@tenant_id, @secret)
      :ok = TenantSecrets.register_tenant(@tenant_id, "new-secret")

      {:ok, secret} = TenantSecrets.get_secret(@tenant_id)
      assert secret == "new-secret"
    end
  end

  describe "unregister_tenant/1" do
    test "removes a tenant" do
      :ok = TenantSecrets.register_tenant(@tenant_id, @secret)
      :ok = TenantSecrets.unregister_tenant(@tenant_id)

      refute TenantSecrets.tenant_exists?(@tenant_id)
    end

    test "succeeds for non-existent tenant" do
      :ok = TenantSecrets.unregister_tenant("non-existent")
    end
  end

  describe "get_secret/1" do
    test "returns secret for registered tenant" do
      :ok = TenantSecrets.register_tenant(@tenant_id, @secret)

      assert {:ok, @secret} = TenantSecrets.get_secret(@tenant_id)
    end

    test "returns error for non-existent tenant" do
      assert {:error, :tenant_not_found} = TenantSecrets.get_secret("non-existent")
    end
  end

  describe "tenant_exists?/1" do
    test "returns true for registered tenant" do
      :ok = TenantSecrets.register_tenant(@tenant_id, @secret)

      assert TenantSecrets.tenant_exists?(@tenant_id)
    end

    test "returns false for non-existent tenant" do
      refute TenantSecrets.tenant_exists?("non-existent")
    end
  end

  describe "list_tenants/0" do
    test "returns list of registered tenants" do
      :ok = TenantSecrets.register_tenant(@tenant_id, @secret)
      :ok = TenantSecrets.register_tenant("another-tenant", "another-secret")

      tenants = TenantSecrets.list_tenants()

      assert @tenant_id in tenants
      assert "another-tenant" in tenants

      TenantSecrets.unregister_tenant("another-tenant")
    end
  end

  describe "register_dev_tenant/1" do
    test "registers tenant with default dev secret" do
      :ok = TenantSecrets.register_dev_tenant(@tenant_id)

      {:ok, secret} = TenantSecrets.get_secret(@tenant_id)
      assert secret == TenantSecrets.default_dev_secret()
    end

    test "uses default tenant id when not specified" do
      :ok = TenantSecrets.register_dev_tenant()

      assert TenantSecrets.tenant_exists?("dev-tenant")
    end
  end

  describe "dev environment" do
    test "dev-tenant is auto-registered in dev/test" do
      # This should already be true from application startup
      assert TenantSecrets.tenant_exists?("dev-tenant")
    end
  end
end
