defmodule LeveeWeb.TenantAdminController do
  use LeveeWeb, :controller

  alias Levee.Auth.TenantSecrets

  @doc """
  List all registered tenants.

  GET /api/admin/tenants
  Returns: {tenants: [{id, has_secret}]}
  """
  def index(conn, _params) do
    tenants =
      TenantSecrets.list_tenants()
      |> Enum.map(fn id -> %{id: id} end)

    json(conn, %{tenants: tenants})
  end

  @doc """
  Register a new tenant with a secret key.

  POST /api/admin/tenants
  Body: {id, secret}
  Returns: {tenant: {id}, message: "..."}
  """
  def create(conn, %{"id" => tenant_id, "secret" => secret}) do
    if TenantSecrets.tenant_exists?(tenant_id) do
      conn
      |> put_status(:conflict)
      |> json(%{error: %{code: "tenant_exists", message: "Tenant already registered"}})
    else
      :ok = TenantSecrets.register_tenant(tenant_id, secret)

      conn
      |> put_status(:created)
      |> json(%{tenant: %{id: tenant_id}, message: "Tenant registered"})
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "missing_fields", message: "Required: id, secret"}})
  end

  @doc """
  Get a tenant's registration status.

  GET /api/admin/tenants/:id
  Returns: {tenant: {id}}
  """
  def show(conn, %{"id" => tenant_id}) do
    if TenantSecrets.tenant_exists?(tenant_id) do
      json(conn, %{tenant: %{id: tenant_id}})
    else
      conn
      |> put_status(:not_found)
      |> json(%{error: %{code: "not_found", message: "Tenant not found"}})
    end
  end

  @doc """
  Update a tenant's secret key.

  PUT /api/admin/tenants/:id
  Body: {secret}
  Returns: {tenant: {id}, message: "..."}
  """
  def update(conn, %{"id" => tenant_id, "secret" => secret}) do
    if TenantSecrets.tenant_exists?(tenant_id) do
      :ok = TenantSecrets.register_tenant(tenant_id, secret)
      json(conn, %{tenant: %{id: tenant_id}, message: "Tenant secret updated"})
    else
      conn
      |> put_status(:not_found)
      |> json(%{error: %{code: "not_found", message: "Tenant not found"}})
    end
  end

  def update(conn, %{"id" => _tenant_id}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "missing_fields", message: "Required: secret"}})
  end

  @doc """
  Unregister a tenant.

  DELETE /api/admin/tenants/:id
  Returns: {message: "..."}
  """
  def delete(conn, %{"id" => tenant_id}) do
    if TenantSecrets.tenant_exists?(tenant_id) do
      :ok = TenantSecrets.unregister_tenant(tenant_id)
      json(conn, %{message: "Tenant unregistered"})
    else
      conn
      |> put_status(:not_found)
      |> json(%{error: %{code: "not_found", message: "Tenant not found"}})
    end
  end
end
