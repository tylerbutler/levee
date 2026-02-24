defmodule Levee.Auth.TenantSecrets do
  @moduledoc """
  Manages tenant registration and secrets for JWT signing and verification.

  Each tenant has a server-generated ID (human-readable), a user-provided name,
  and two rotating secrets. Both secrets are valid for JWT verification (try-both),
  and secret1 is used for signing new tokens.
  """

  use GenServer

  require Logger

  @default_dev_secret "levee-dev-secret-change-in-production"

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Creates a new tenant with a server-generated ID and two secrets.
  Returns `{:ok, %{id, name, secret1, secret2}}`.
  """
  @spec create_tenant(String.t()) :: {:ok, map()}
  def create_tenant(name) do
    GenServer.call(__MODULE__, {:create_tenant, name})
  end

  @doc """
  Returns tenant info (id, name) without secrets.
  """
  @spec get_tenant(String.t()) :: {:ok, map()} | {:error, :tenant_not_found}
  def get_tenant(tenant_id) do
    GenServer.call(__MODULE__, {:get_tenant, tenant_id})
  end

  @doc """
  Returns both secrets for a tenant.
  """
  @spec get_secrets(String.t()) ::
          {:ok, %{secret1: String.t(), secret2: String.t()}} | {:error, :tenant_not_found}
  def get_secrets(tenant_id) do
    GenServer.call(__MODULE__, {:get_secrets, tenant_id})
  end

  @doc """
  Regenerates one of a tenant's secrets (slot 1 or 2).
  Returns `{:ok, new_secret}`.
  """
  @spec regenerate_secret(String.t(), 1 | 2) ::
          {:ok, String.t()} | {:error, :tenant_not_found | :invalid_slot}
  def regenerate_secret(tenant_id, slot) when slot in [1, 2] do
    GenServer.call(__MODULE__, {:regenerate_secret, tenant_id, slot})
  end

  def regenerate_secret(_tenant_id, _slot) do
    {:error, :invalid_slot}
  end

  @doc """
  Backward-compatible: registers a tenant with an explicit ID and secret.
  Stores the secret as secret1, generates secret2.
  """
  @spec register_tenant(String.t(), String.t()) :: :ok
  def register_tenant(tenant_id, secret) do
    GenServer.call(__MODULE__, {:register_tenant, tenant_id, secret})
  end

  @spec unregister_tenant(String.t()) :: :ok
  def unregister_tenant(tenant_id) do
    GenServer.call(__MODULE__, {:unregister_tenant, tenant_id})
  end

  @doc """
  Backward-compatible: returns secret1 for the tenant.
  """
  @spec get_secret(String.t()) :: {:ok, String.t()} | {:error, :tenant_not_found}
  def get_secret(tenant_id) do
    GenServer.call(__MODULE__, {:get_secret, tenant_id})
  end

  @spec tenant_exists?(String.t()) :: boolean()
  def tenant_exists?(tenant_id) do
    GenServer.call(__MODULE__, {:tenant_exists?, tenant_id})
  end

  @spec list_tenants() :: [String.t()]
  def list_tenants do
    GenServer.call(__MODULE__, :list_tenants)
  end

  @doc """
  Lists tenants with their names (no secrets).
  """
  @spec list_tenants_with_names() :: [%{id: String.t(), name: String.t()}]
  def list_tenants_with_names do
    GenServer.call(__MODULE__, :list_tenants_with_names)
  end

  @spec register_dev_tenant(String.t()) :: :ok
  def register_dev_tenant(tenant_id \\ "dev-tenant") do
    register_tenant(tenant_id, @default_dev_secret)
  end

  @spec default_dev_secret() :: String.t()
  def default_dev_secret, do: @default_dev_secret

  @doc """
  Generates a cryptographically secure 32-byte hex secret.
  """
  @spec generate_secret() :: String.t()
  def generate_secret do
    :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
  end

  defp generate_tenant_id(existing_tenants, retries \\ 5)

  defp generate_tenant_id(_existing_tenants, 0) do
    # Fallback: append random suffix
    base = UniqueNamesGenerator.generate([:adjectives, :colors, :animals], %{separator: "-"})
    suffix = :crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower)
    base <> "-" <> suffix
  end

  defp generate_tenant_id(existing_tenants, retries) do
    id = UniqueNamesGenerator.generate([:adjectives, :colors, :animals], %{separator: "-"})

    if Map.has_key?(existing_tenants, id) do
      generate_tenant_id(existing_tenants, retries - 1)
    else
      id
    end
  end

  # Server callbacks

  @impl true
  def init(opts) do
    initial_tenants = Keyword.get(opts, :tenants, %{})

    state = %{tenants: initial_tenants}

    state =
      case {System.get_env("LEVEE_TENANT_ID"), System.get_env("LEVEE_TENANT_KEY")} do
        {tenant_id, tenant_key} when is_binary(tenant_id) and is_binary(tenant_key) ->
          Logger.info("Registering tenant from environment: #{tenant_id}")
          data = %{name: tenant_id, secret1: tenant_key, secret2: generate_secret()}
          put_in(state.tenants[tenant_id], data)

        _ ->
          state
      end

    {:ok, state}
  end

  @impl true
  def handle_call({:create_tenant, name}, _from, state) do
    id = generate_tenant_id(state.tenants)
    secret1 = generate_secret()
    secret2 = generate_secret()
    data = %{name: name, secret1: secret1, secret2: secret2}
    new_state = put_in(state.tenants[id], data)

    result = %{id: id, name: name, secret1: secret1, secret2: secret2}
    Logger.info("Created tenant: #{id} (#{name})")
    {:reply, {:ok, result}, new_state}
  end

  def handle_call({:get_tenant, tenant_id}, _from, state) do
    case Map.get(state.tenants, tenant_id) do
      nil -> {:reply, {:error, :tenant_not_found}, state}
      data -> {:reply, {:ok, %{id: tenant_id, name: data.name}}, state}
    end
  end

  def handle_call({:get_secrets, tenant_id}, _from, state) do
    case Map.get(state.tenants, tenant_id) do
      nil -> {:reply, {:error, :tenant_not_found}, state}
      data -> {:reply, {:ok, %{secret1: data.secret1, secret2: data.secret2}}, state}
    end
  end

  def handle_call({:regenerate_secret, tenant_id, slot}, _from, state) do
    case Map.get(state.tenants, tenant_id) do
      nil ->
        {:reply, {:error, :tenant_not_found}, state}

      data ->
        new_secret = generate_secret()
        key = if slot == 1, do: :secret1, else: :secret2
        new_data = Map.put(data, key, new_secret)
        new_state = put_in(state.tenants[tenant_id], new_data)
        Logger.info("Regenerated secret#{slot} for tenant: #{tenant_id}")
        {:reply, {:ok, new_secret}, new_state}
    end
  end

  def handle_call({:register_tenant, tenant_id, secret}, _from, state) do
    Logger.info("Registering tenant: #{tenant_id}")
    data = %{name: tenant_id, secret1: secret, secret2: generate_secret()}
    new_state = put_in(state.tenants[tenant_id], data)
    {:reply, :ok, new_state}
  end

  def handle_call({:unregister_tenant, tenant_id}, _from, state) do
    Logger.info("Unregistering tenant: #{tenant_id}")
    new_state = update_in(state.tenants, &Map.delete(&1, tenant_id))
    {:reply, :ok, new_state}
  end

  def handle_call({:get_secret, tenant_id}, _from, state) do
    case Map.get(state.tenants, tenant_id) do
      nil -> {:reply, {:error, :tenant_not_found}, state}
      data -> {:reply, {:ok, data.secret1}, state}
    end
  end

  def handle_call({:tenant_exists?, tenant_id}, _from, state) do
    {:reply, Map.has_key?(state.tenants, tenant_id), state}
  end

  def handle_call(:list_tenants, _from, state) do
    {:reply, Map.keys(state.tenants), state}
  end

  def handle_call(:list_tenants_with_names, _from, state) do
    list =
      state.tenants
      |> Enum.map(fn {id, data} -> %{id: id, name: data.name} end)

    {:reply, list, state}
  end
end
