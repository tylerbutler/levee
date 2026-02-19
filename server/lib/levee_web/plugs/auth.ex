defmodule LeveeWeb.Plugs.Auth do
  @moduledoc """
  Authentication plug for Fluid Framework HTTP routes.

  Extracts and validates JWT tokens from the Authorization header.
  Validates:
  - JWT signature using tenant secret
  - Token expiration
  - Tenant match (from URL parameter)
  - Document match (from URL parameter, if present)
  - Required scopes (configurable per route)

  ## Usage

  In your router:

      pipeline :authenticated do
        plug LeveeWeb.Plugs.Auth
      end

      pipeline :read_access do
        plug LeveeWeb.Plugs.Auth, scopes: ["doc:read"]
      end

      pipeline :write_access do
        plug LeveeWeb.Plugs.Auth, scopes: ["doc:read", "doc:write"]
      end

  The plug stores validated claims in `conn.assigns.claims`.

  ## Options

  - `:scopes` - List of required scopes (default: [])
  - `:tenant_param` - URL parameter name for tenant ID (default: "tenant_id")
  - `:document_param` - URL parameter name for document ID (default: "id")
  - `:validate_document` - Whether to validate document ID (default: true)
  """

  import Plug.Conn

  alias Levee.Auth.JWT

  require Logger

  @behaviour Plug

  @default_opts %{
    scopes: [],
    tenant_param: "tenant_id",
    document_param: "id",
    validate_document: true
  }

  @impl true
  def init(opts) do
    Map.merge(@default_opts, Map.new(opts))
  end

  @impl true
  def call(conn, opts) do
    with {:ok, token} <- extract_token(conn),
         {:ok, tenant_id} <- get_tenant_id(conn, opts),
         {:ok, claims} <- JWT.verify(token, tenant_id),
         :ok <- validate_claims(claims, conn, opts) do
      conn
      |> assign(:claims, claims)
      |> assign(:authenticated, true)
    else
      {:error, reason} ->
        {code, message} = error_response(reason)

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(code, Jason.encode!(%{error: message}))
        |> halt()
    end
  end

  @doc """
  Extracts the Bearer token from the Authorization header.

  ## Returns
  - `{:ok, token}` if token is present
  - `{:error, :missing_token}` if no token
  - `{:error, :invalid_auth_header}` if malformed
  """
  @spec extract_token(Plug.Conn.t()) :: {:ok, String.t()} | {:error, atom()}
  def extract_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        {:ok, String.trim(token)}

      [_other] ->
        {:error, :invalid_auth_header}

      [] ->
        {:error, :missing_token}

      _ ->
        {:error, :invalid_auth_header}
    end
  end

  @doc """
  Validates claims against request parameters.
  """
  @spec validate_claims(JWT.token_claims(), Plug.Conn.t(), map()) :: :ok | {:error, term()}
  def validate_claims(claims, conn, opts) do
    with :ok <- validate_expiration(claims),
         {:ok, tenant_id} <- get_tenant_id(conn, opts),
         :ok <- validate_tenant(claims, tenant_id),
         :ok <- validate_document(claims, conn, opts),
         :ok <- validate_scopes(claims, opts) do
      :ok
    end
  end

  # Private functions

  defp get_tenant_id(conn, opts) do
    param_name = opts.tenant_param

    case conn.params[param_name] || conn.path_params[param_name] do
      nil -> {:error, :missing_tenant_id}
      tenant_id -> {:ok, tenant_id}
    end
  end

  defp validate_expiration(claims) do
    case JWT.expired?(claims) do
      true -> {:error, :token_expired}
      false -> :ok
    end
  end

  defp validate_tenant(claims, tenant_id) do
    if claims.tenantId == tenant_id do
      :ok
    else
      {:error, {:tenant_mismatch, claims.tenantId, tenant_id}}
    end
  end

  defp validate_document(_claims, _conn, %{validate_document: false}), do: :ok

  defp validate_document(claims, conn, opts) do
    param_name = opts.document_param

    case conn.params[param_name] || conn.path_params[param_name] do
      nil ->
        :ok

      document_id when document_id == claims.documentId ->
        :ok

      document_id ->
        {:error, {:document_mismatch, claims.documentId, document_id}}
    end
  end

  defp validate_scopes(claims, opts) do
    missing = Enum.reject(opts.scopes, &JWT.has_scope?(claims, &1))

    case missing do
      [] -> :ok
      _ -> {:error, {:missing_scopes, missing}}
    end
  end

  defp error_response(:missing_token) do
    {401, "Missing Authorization header"}
  end

  defp error_response(:invalid_auth_header) do
    {401, "Invalid Authorization header format. Expected: Bearer <token>"}
  end

  defp error_response(:invalid_signature) do
    {401, "Invalid token signature"}
  end

  defp error_response(:token_expired) do
    {401, "Token has expired"}
  end

  defp error_response({:jwt_decode_error, _reason}) do
    {401, "Invalid token format"}
  end

  defp error_response({:tenant_secret_not_found, _}) do
    {401, "Unknown tenant"}
  end

  defp error_response(:missing_tenant_id) do
    {400, "Missing tenant ID in request"}
  end

  defp error_response({:tenant_mismatch, token_tenant, request_tenant}) do
    Logger.warning("Tenant mismatch: token=#{token_tenant}, request=#{request_tenant}")

    {403, "Token not valid for this tenant"}
  end

  defp error_response({:document_mismatch, token_doc, request_doc}) do
    Logger.warning("Document mismatch: token=#{token_doc}, request=#{request_doc}")

    {403, "Token not valid for this document"}
  end

  defp error_response({:missing_scopes, scopes}) do
    {403, "Missing required scopes: #{Enum.join(scopes, ", ")}"}
  end

  defp error_response(reason) do
    Logger.error("Unexpected auth error: #{inspect(reason)}")
    {500, "Authentication error"}
  end
end
