defmodule LeveeWeb.TokenMintController do
  use LeveeWeb, :controller

  alias Levee.Auth.JWT

  def create(conn, %{"tenant_id" => tenant_id, "documentId" => document_id}) do
    # TODO: Implement tenant membership checks. Currently any authenticated user
    # can mint tokens for any tenant. See GitHub issue for tracking.
    user = conn.assigns.current_user

    claims = %{
      documentId: document_id,
      tenantId: tenant_id,
      scopes: ["doc:read", "doc:write", "summary:write"],
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

  def create(conn, %{"tenant_id" => _tenant_id}) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Missing required field: documentId"})
  end
end
