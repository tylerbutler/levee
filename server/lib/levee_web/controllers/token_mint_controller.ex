defmodule LeveeWeb.TokenMintController do
  use LeveeWeb, :controller

  alias Levee.Auth.{JWT, GleamBridge}

  @all_scopes ["doc:read", "doc:write", "summary:read", "summary:write"]

  def create(conn, %{"tenant_id" => tenant_id, "documentId" => document_id}) do
    user = conn.assigns.current_user

    case GleamBridge.get_membership(user.id, tenant_id) do
      {:ok, membership} ->
        scopes = GleamBridge.filter_scopes_for_role(@all_scopes, membership.role)
        mint_token(conn, tenant_id, document_id, user, scopes)

      :error ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "Not a member of this tenant"})
    end
  end

  def create(conn, %{"tenant_id" => _tenant_id}) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Missing required field: documentId"})
  end

  defp mint_token(conn, tenant_id, document_id, user, scopes) do
    claims = %{
      documentId: document_id,
      tenantId: tenant_id,
      scopes: scopes,
      user: %{id: user.id},
      ver: "1.0",
      iat: System.system_time(:second),
      exp: System.system_time(:second) + 3600
    }

    case JWT.sign(claims, tenant_id) do
      {:ok, token} ->
        conn
        |> put_status(:ok)
        |> json(%{jwt: token, expiresIn: 3600, user: %{id: user.id, name: user.display_name}})

      {:error, {:tenant_secret_not_found, _}} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Tenant not found"})
    end
  end
end
