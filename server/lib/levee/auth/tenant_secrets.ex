defmodule Levee.Auth.TenantSecrets do
  @moduledoc """
  Manages tenant secrets for JWT signing and verification.

  This is an in-memory implementation for development and testing.
  In production, this would be backed by a secure secret store.

  Tenants must be registered with a secret before tokens can be
  signed or verified.
  """

  use GenServer

  require Logger

  # Default secret for development/testing
  @default_dev_secret "levee-dev-secret-change-in-production"

  # Client API

  @doc """
  Starts the tenant secrets server.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Registers a tenant with a secret.

  ## Parameters
  - tenant_id: Unique tenant identifier
  - secret: Secret key for JWT signing (minimum 32 bytes recommended)

  ## Returns
  - :ok
  """
  @spec register_tenant(String.t(), String.t()) :: :ok
  def register_tenant(tenant_id, secret) do
    GenServer.call(__MODULE__, {:register_tenant, tenant_id, secret})
  end

  @doc """
  Unregisters a tenant.

  ## Parameters
  - tenant_id: Tenant identifier to remove

  ## Returns
  - :ok
  """
  @spec unregister_tenant(String.t()) :: :ok
  def unregister_tenant(tenant_id) do
    GenServer.call(__MODULE__, {:unregister_tenant, tenant_id})
  end

  @doc """
  Gets the secret for a tenant.

  ## Parameters
  - tenant_id: Tenant identifier

  ## Returns
  - `{:ok, secret}` if tenant exists
  - `{:error, :tenant_not_found}` if tenant doesn't exist
  """
  @spec get_secret(String.t()) :: {:ok, String.t()} | {:error, :tenant_not_found}
  def get_secret(tenant_id) do
    GenServer.call(__MODULE__, {:get_secret, tenant_id})
  end

  @doc """
  Checks if a tenant is registered.

  ## Parameters
  - tenant_id: Tenant identifier

  ## Returns
  - boolean
  """
  @spec tenant_exists?(String.t()) :: boolean()
  def tenant_exists?(tenant_id) do
    GenServer.call(__MODULE__, {:tenant_exists?, tenant_id})
  end

  @doc """
  Lists all registered tenant IDs.

  ## Returns
  - List of tenant IDs
  """
  @spec list_tenants() :: [String.t()]
  def list_tenants do
    GenServer.call(__MODULE__, :list_tenants)
  end

  @doc """
  Registers a development tenant with the default secret.
  Useful for testing.

  ## Parameters
  - tenant_id: Tenant identifier (defaults to "dev-tenant")

  ## Returns
  - :ok
  """
  @spec register_dev_tenant(String.t()) :: :ok
  def register_dev_tenant(tenant_id \\ "dev-tenant") do
    register_tenant(tenant_id, @default_dev_secret)
  end

  @doc """
  Gets the default development secret.
  Only use for testing!
  """
  @spec default_dev_secret() :: String.t()
  def default_dev_secret, do: @default_dev_secret

  # Server callbacks

  @impl true
  def init(opts) do
    # Initialize with any tenants passed in opts
    initial_tenants = Keyword.get(opts, :tenants, %{})

    state = %{
      tenants: initial_tenants
    }

    # Auto-register tenant from environment variables if provided
    state =
      case {System.get_env("LEVEE_TENANT_ID"), System.get_env("LEVEE_TENANT_KEY")} do
        {tenant_id, tenant_key} when is_binary(tenant_id) and is_binary(tenant_key) ->
          Logger.info("Registering tenant from environment: #{tenant_id}")
          put_in(state.tenants[tenant_id], tenant_key)

        _ ->
          state
      end

    {:ok, state}
  end

  @impl true
  def handle_call({:register_tenant, tenant_id, secret}, _from, state) do
    Logger.info("Registering tenant: #{tenant_id}")
    new_state = put_in(state.tenants[tenant_id], secret)
    {:reply, :ok, new_state}
  end

  def handle_call({:unregister_tenant, tenant_id}, _from, state) do
    Logger.info("Unregistering tenant: #{tenant_id}")
    new_state = update_in(state.tenants, &Map.delete(&1, tenant_id))
    {:reply, :ok, new_state}
  end

  def handle_call({:get_secret, tenant_id}, _from, state) do
    case Map.get(state.tenants, tenant_id) do
      nil ->
        {:reply, {:error, :tenant_not_found}, state}

      secret ->
        {:reply, {:ok, secret}, state}
    end
  end

  def handle_call({:tenant_exists?, tenant_id}, _from, state) do
    {:reply, Map.has_key?(state.tenants, tenant_id), state}
  end

  def handle_call(:list_tenants, _from, state) do
    {:reply, Map.keys(state.tenants), state}
  end
end
