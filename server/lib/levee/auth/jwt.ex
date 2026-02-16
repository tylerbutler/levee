defmodule Levee.Auth.JWT do
  @moduledoc """
  JWT signing and verification for Fluid Framework authentication.

  Delegates to the Gleam levee_auth token module (backed by gwt) for
  cryptographic operations. The Gleam module handles HS256 signing,
  signature verification, and expiration checking.

  Token Claims Structure:
  - documentId: Document ID this token grants access to
  - scopes: Permission scopes granted (doc:read, doc:write, summary:write)
  - tenantId: Tenant ID
  - user: User identity with at least an `id` field
  - iat: Issued At timestamp (Unix seconds)
  - exp: Expiration timestamp (Unix seconds)
  - ver: Token version
  - jti: JWT ID (optional, unique token identifier)
  """

  alias Levee.Auth.TenantSecrets

  require Logger

  # Tell compiler these Gleam modules will exist at runtime
  @compile {:no_warn_undefined, [:token]}

  # Standard permission scopes
  @scope_doc_read "doc:read"
  @scope_doc_write "doc:write"
  @scope_summary_write "summary:write"

  # Token version
  @token_version "1.0"

  # Default expiration: 1 hour
  @default_expiration_seconds 3600

  @type token_claims :: %{
          required(:documentId) => String.t(),
          required(:scopes) => [String.t()],
          required(:tenantId) => String.t(),
          required(:user) => %{required(:id) => String.t()},
          required(:iat) => integer(),
          required(:exp) => integer(),
          required(:ver) => String.t(),
          optional(:jti) => String.t()
        }

  @doc """
  Returns the standard permission scopes.
  """
  def scope_doc_read, do: @scope_doc_read
  def scope_doc_write, do: @scope_doc_write
  def scope_summary_write, do: @scope_summary_write

  @doc """
  Signs a JWT token for the given claims and tenant.

  Delegates to the Gleam token module for HS256 signing via gwt.

  ## Parameters
  - claims: Map of token claims (with :documentId, :tenantId, :user, :scopes, etc.)
  - tenant_id: Tenant ID to look up the signing secret

  ## Returns
  - `{:ok, token}` on success
  - `{:error, reason}` on failure
  """
  @spec sign(token_claims(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def sign(claims, tenant_id) do
    case TenantSecrets.get_secret(tenant_id) do
      {:ok, secret} ->
        user_id = get_in(claims, [:user, :id]) || ""
        tenant = claims[:tenantId] || tenant_id
        doc_id = claims[:documentId] || ""
        scopes_list = claims[:scopes] || []
        iat = claims[:iat] || System.system_time(:second)
        exp = claims[:exp] || iat + @default_expiration_seconds
        jti = claims[:jti]

        gleam_scopes = Enum.map(scopes_list, &string_to_gleam_scope/1)
        token_id = if jti, do: {:some, jti}, else: :none

        gleam_claims =
          {:token_claims, user_id, tenant, doc_id, gleam_scopes, iat, exp, token_id}

        config = {:token_config, secret, @default_expiration_seconds}

        token = :token.create(gleam_claims, config)
        {:ok, token}

      {:error, reason} ->
        {:error, {:tenant_secret_not_found, reason}}
    end
  end

  @doc """
  Verifies a JWT token and returns the claims.

  Delegates to the Gleam token module which uses gwt for verification.
  Note: expired tokens are rejected during verification (gwt checks
  expiration automatically).

  ## Parameters
  - token: The JWT token string
  - tenant_id: Tenant ID to look up the verification secret

  ## Returns
  - `{:ok, claims}` with decoded claims on success
  - `{:error, reason}` on failure
  """
  @spec verify(String.t(), String.t()) :: {:ok, token_claims()} | {:error, term()}
  def verify(token, tenant_id) do
    case TenantSecrets.get_secret(tenant_id) do
      {:ok, secret} ->
        case :token.verify(token, secret) do
          {:ok, {:token_claims, user_id, t_id, doc_id, gleam_scopes, iat, exp, token_id}} ->
            scopes = Enum.map(gleam_scopes, &gleam_scope_to_string/1)

            jti =
              case token_id do
                {:some, id} -> id
                :none -> nil
              end

            {:ok,
             %{
               documentId: doc_id,
               scopes: scopes,
               tenantId: t_id,
               user: %{id: user_id},
               iat: iat,
               exp: exp,
               ver: @token_version,
               jti: jti
             }}

          {:error, :invalid_signature} ->
            {:error, :invalid_signature}

          {:error, :token_expired} ->
            {:error, :token_expired}

          {:error, :malformed_token} ->
            {:error, :malformed_token}

          {:error, :missing_claims} ->
            {:error, :missing_claims}

          {:error, _} ->
            {:error, :token_verification_failed}
        end

      {:error, reason} ->
        {:error, {:tenant_secret_not_found, reason}}
    end
  end

  @doc """
  Generates a token for testing purposes.

  ## Parameters
  - tenant_id: Tenant ID
  - document_id: Document ID
  - user_id: User ID
  - opts: Optional parameters
    - scopes: List of scopes (default: ["doc:read", "doc:write"])
    - expires_in: Expiration in seconds (default: 3600)
    - jti: JWT ID (default: generated UUID)

  ## Returns
  - `{:ok, token}` on success
  - `{:error, reason}` on failure
  """
  @spec generate_test_token(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def generate_test_token(tenant_id, document_id, user_id, opts \\ []) do
    scopes = Keyword.get(opts, :scopes, [@scope_doc_read, @scope_doc_write])
    expires_in = Keyword.get(opts, :expires_in, @default_expiration_seconds)
    jti = Keyword.get(opts, :jti, generate_jti())

    now = System.system_time(:second)

    claims = %{
      documentId: document_id,
      scopes: scopes,
      tenantId: tenant_id,
      user: %{id: user_id},
      iat: now,
      exp: now + expires_in,
      ver: @token_version,
      jti: jti
    }

    sign(claims, tenant_id)
  end

  @doc """
  Generates a read-only token for testing.
  """
  @spec generate_read_only_token(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def generate_read_only_token(tenant_id, document_id, user_id, opts \\ []) do
    opts = Keyword.put(opts, :scopes, [@scope_doc_read])
    generate_test_token(tenant_id, document_id, user_id, opts)
  end

  @doc """
  Generates a token with all scopes (read, write, summary).
  """
  @spec generate_full_access_token(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def generate_full_access_token(tenant_id, document_id, user_id, opts \\ []) do
    opts = Keyword.put(opts, :scopes, [@scope_doc_read, @scope_doc_write, @scope_summary_write])
    generate_test_token(tenant_id, document_id, user_id, opts)
  end

  @doc """
  Checks if the given claims have expired.
  """
  @spec expired?(token_claims()) :: boolean()
  def expired?(claims) do
    current_time = System.system_time(:second)
    Map.get(claims, :exp, 0) < current_time
  end

  @doc """
  Checks if the claims have the required scope.
  """
  @spec has_scope?(token_claims(), String.t()) :: boolean()
  def has_scope?(claims, required_scope) do
    scopes = Map.get(claims, :scopes, [])
    required_scope in scopes
  end

  @doc """
  Checks if the claims have read permission.
  """
  @spec has_read_scope?(token_claims()) :: boolean()
  def has_read_scope?(claims), do: has_scope?(claims, @scope_doc_read)

  @doc """
  Checks if the claims have write permission.
  """
  @spec has_write_scope?(token_claims()) :: boolean()
  def has_write_scope?(claims), do: has_scope?(claims, @scope_doc_write)

  @doc """
  Checks if the claims have summary write permission.
  """
  @spec has_summary_write_scope?(token_claims()) :: boolean()
  def has_summary_write_scope?(claims), do: has_scope?(claims, @scope_summary_write)

  # Private functions

  defp generate_jti do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  defp string_to_gleam_scope("doc:read"), do: :doc_read
  defp string_to_gleam_scope("doc:write"), do: :doc_write
  defp string_to_gleam_scope("summary:read"), do: :summary_read
  defp string_to_gleam_scope("summary:write"), do: :summary_write

  defp gleam_scope_to_string(:doc_read), do: "doc:read"
  defp gleam_scope_to_string(:doc_write), do: "doc:write"
  defp gleam_scope_to_string(:summary_read), do: "summary:read"
  defp gleam_scope_to_string(:summary_write), do: "summary:write"
end
