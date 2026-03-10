defmodule Levee.Auth.TenantSecrets do
  @moduledoc """
  Manages tenant registration and secrets for JWT signing and verification.

  Each tenant has a server-generated ID (human-readable), a user-provided name,
  and two rotating secrets. Both secrets are valid for JWT verification (try-both),
  and secret1 is used for signing new tokens.

  This module delegates to a Gleam OTP actor for state management.
  """

  @compile {:no_warn_undefined, [:tenant_secrets]}

  @default_dev_secret "levee-dev-secret-change-in-production"

  defp get_actor, do: Levee.Auth.TenantSecretsSupervisor.get_actor()

  @spec create_tenant(String.t()) :: {:ok, map()}
  def create_tenant(name) do
    case :tenant_secrets.create_tenant(get_actor(), name) do
      {:ok, {:tenant_with_secrets, id, name, secret1, secret2}} ->
        {:ok, %{id: id, name: name, secret1: secret1, secret2: secret2}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec get_tenant(String.t()) :: {:ok, map()} | {:error, :tenant_not_found}
  def get_tenant(tenant_id) do
    case :tenant_secrets.get_tenant(get_actor(), tenant_id) do
      {:ok, {:tenant_info, id, name}} -> {:ok, %{id: id, name: name}}
      {:error, :tenant_not_found} -> {:error, :tenant_not_found}
    end
  end

  @spec get_secrets(String.t()) ::
          {:ok, %{secret1: String.t(), secret2: String.t()}} | {:error, :tenant_not_found}
  def get_secrets(tenant_id) do
    case :tenant_secrets.get_secrets(get_actor(), tenant_id) do
      {:ok, {secret1, secret2}} -> {:ok, %{secret1: secret1, secret2: secret2}}
      {:error, :tenant_not_found} -> {:error, :tenant_not_found}
    end
  end

  @spec regenerate_secret(String.t(), 1 | 2) ::
          {:ok, String.t()} | {:error, :tenant_not_found | :invalid_slot}
  def regenerate_secret(tenant_id, slot) when slot in [1, 2] do
    gleam_slot = if slot == 1, do: :slot1, else: :slot2
    :tenant_secrets.regenerate_secret(get_actor(), tenant_id, gleam_slot)
  end

  def regenerate_secret(_tenant_id, _slot), do: {:error, :invalid_slot}

  @spec register_tenant(String.t(), String.t()) :: :ok
  def register_tenant(tenant_id, secret) do
    :tenant_secrets.register_tenant(get_actor(), tenant_id, secret)
    :ok
  end

  @spec unregister_tenant(String.t()) :: :ok
  def unregister_tenant(tenant_id) do
    :tenant_secrets.unregister_tenant(get_actor(), tenant_id)
    :ok
  end

  @spec get_secret(String.t()) :: {:ok, String.t()} | {:error, :tenant_not_found}
  def get_secret(tenant_id) do
    :tenant_secrets.get_secret(get_actor(), tenant_id)
  end

  @spec tenant_exists?(String.t()) :: boolean()
  def tenant_exists?(tenant_id) do
    :tenant_secrets.tenant_exists(get_actor(), tenant_id)
  end

  @spec list_tenants() :: [String.t()]
  def list_tenants do
    :tenant_secrets.list_tenants(get_actor())
  end

  @spec list_tenants_with_names() :: [%{id: String.t(), name: String.t()}]
  def list_tenants_with_names do
    get_actor()
    |> :tenant_secrets.list_tenants_with_names()
    |> Enum.map(fn {:tenant_info, id, name} -> %{id: id, name: name} end)
  end

  @spec register_dev_tenant(String.t()) :: :ok
  def register_dev_tenant(tenant_id \\ "dev-tenant") do
    register_tenant(tenant_id, @default_dev_secret)
  end

  @spec default_dev_secret() :: String.t()
  def default_dev_secret, do: @default_dev_secret

  @spec generate_secret() :: String.t()
  def generate_secret do
    :tenant_secrets.generate_secret()
  end
end
