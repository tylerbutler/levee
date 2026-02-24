defmodule LeveeWeb.TenantAdminController do
  use LeveeWeb, :controller

  alias Levee.Auth.TenantSecrets

  def index(conn, _params) do
    tenants = TenantSecrets.list_tenants_with_names()
    json(conn, %{tenants: tenants})
  end

  def create(conn, %{"name" => name}) do
    {:ok, tenant} = TenantSecrets.create_tenant(name)

    conn
    |> put_status(:created)
    |> json(%{tenant: tenant})
  end

  def create(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "missing_fields", message: "Required: name"}})
  end

  def show(conn, %{"id" => tenant_id}) do
    case TenantSecrets.get_tenant(tenant_id) do
      {:ok, tenant} ->
        json(conn, %{tenant: tenant})

      {:error, :tenant_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "not_found", message: "Tenant not found"}})
    end
  end

  def regenerate_secret(conn, %{"id" => tenant_id, "slot" => slot_str}) do
    case Integer.parse(slot_str) do
      {slot, ""} when slot in [1, 2] ->
        case TenantSecrets.regenerate_secret(tenant_id, slot) do
          {:ok, new_secret} ->
            json(conn, %{secret: new_secret})

          {:error, :tenant_not_found} ->
            conn
            |> put_status(:not_found)
            |> json(%{error: %{code: "not_found", message: "Tenant not found"}})
        end

      _ ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: %{code: "invalid_slot", message: "Slot must be 1 or 2"}})
    end
  end

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
