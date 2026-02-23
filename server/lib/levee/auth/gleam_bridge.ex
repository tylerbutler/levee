defmodule Levee.Auth.GleamBridge do
  @moduledoc """
  Elixir bridge to Gleam authentication modules.

  Provides idiomatic Elixir wrappers around the Gleam levee_auth package
  for user management, tenant operations, sessions, invites, and tokens.

  The Gleam modules compile to BEAM bytecode, so we can call
  them directly using the Erlang module naming convention.
  """

  # Gleam modules at src/ root compile to simple atoms (not namespaced)
  # e.g., src/password.gleam -> :password, not :levee_auth@password
  @gleam_password :password
  @gleam_user :user
  @gleam_tenant :tenant
  @gleam_session :session
  @gleam_invite :invite
  @gleam_token :token

  # Tell compiler these modules will exist at runtime
  @compile {:no_warn_undefined,
            [
              :password,
              :user,
              :tenant,
              :session,
              :invite,
              :token,
              :scopes
            ]}

  # ─────────────────────────────────────────────────────────────────────────────
  # Password Functions
  # ─────────────────────────────────────────────────────────────────────────────

  @doc """
  Hash a password using PBKDF2-SHA256.
  """
  def hash_password(password) do
    case @gleam_password.hash(password) do
      {:ok, hash} -> {:ok, hash}
      {:error, _} -> {:error, :hashing_failed}
    end
  end

  @doc """
  Verify a password against a hash.
  """
  def verify_password(password, hash) do
    @gleam_password.matches(password, hash)
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # User Functions
  # ─────────────────────────────────────────────────────────────────────────────

  @doc """
  Create a new user.
  """
  def create_user(email, password, display_name) do
    case @gleam_user.create(email, password, display_name) do
      {:ok, user} -> {:ok, gleam_user_to_map(user)}
      {:error, :invalid_email} -> {:error, :invalid_email}
      {:error, :password_too_short} -> {:error, :password_too_short}
      {:error, _} -> {:error, :user_creation_failed}
    end
  end

  @doc """
  Create a new user from OAuth (no password).
  """
  def create_oauth_user(email, display_name, github_id) do
    user = @gleam_user.create_oauth(email, display_name, github_id)
    gleam_user_to_map(user)
  end

  @doc """
  Verify a password against a user's stored hash.
  """
  def verify_user_password(user, password) do
    @gleam_password.matches(password, user.password_hash)
  end

  @doc """
  Update a user's display name.
  """
  def update_display_name(user, new_name) do
    gleam_user = map_to_gleam_user(user)
    updated = @gleam_user.update_display_name(gleam_user, new_name)
    gleam_user_to_map(updated)
  end

  @doc """
  Change a user's password.
  """
  def change_password(user, current_password, new_password) do
    gleam_user = map_to_gleam_user(user)

    case @gleam_user.change_password(gleam_user, current_password, new_password) do
      {:ok, updated} -> {:ok, gleam_user_to_map(updated)}
      {:error, :invalid_current_password} -> {:error, :invalid_current_password}
      {:error, :password_too_short} -> {:error, :password_too_short}
      {:error, _} -> {:error, :password_change_failed}
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Tenant Functions
  # ─────────────────────────────────────────────────────────────────────────────

  @doc """
  Create a new tenant. Returns {tenant, owner_membership}.
  """
  def create_tenant(name, slug, owner_id) do
    case @gleam_tenant.create(name, slug, owner_id) do
      {:ok, {tenant, membership}} ->
        {:ok, {gleam_tenant_to_map(tenant), gleam_membership_to_map(membership)}}

      {:error, :invalid_name} ->
        {:error, :invalid_name}

      {:error, :invalid_slug} ->
        {:error, :invalid_slug}

      {:error, _} ->
        {:error, :tenant_creation_failed}
    end
  end

  @doc """
  Check if a role can manage members.
  """
  def can_manage_members?(role) do
    @gleam_tenant.can_manage_members(role)
  end

  @doc """
  Check if a role can update tenant settings.
  """
  def can_update_tenant?(role) do
    @gleam_tenant.can_update_tenant(role)
  end

  @doc """
  Check if a role can delete the tenant.
  """
  def can_delete_tenant?(role) do
    @gleam_tenant.can_delete_tenant(role)
  end

  @doc """
  Create a membership for a user in a tenant.
  """
  def create_membership(user_id, tenant_id, role) do
    membership = @gleam_tenant.create_membership(user_id, tenant_id, role)
    gleam_membership_to_map(membership)
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Session Functions
  # ─────────────────────────────────────────────────────────────────────────────

  @doc """
  Create a new session.
  """
  def create_session(user_id, tenant_id) do
    session = @gleam_session.create(user_id, tenant_id)
    gleam_session_to_map(session)
  end

  @doc """
  Check if a session is valid (not expired).
  """
  def is_session_valid?(session) do
    gleam_session = map_to_gleam_session(session)
    @gleam_session.is_valid(gleam_session)
  end

  @doc """
  Update the last activity timestamp.
  """
  def touch_session(session) do
    gleam_session = map_to_gleam_session(session)
    touched = @gleam_session.touch(gleam_session)
    gleam_session_to_map(touched)
  end

  @doc """
  Extend a session's expiration.
  """
  def extend_session(session, seconds) do
    gleam_session = map_to_gleam_session(session)
    extended = @gleam_session.extend(gleam_session, seconds)
    gleam_session_to_map(extended)
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Invite Functions
  # ─────────────────────────────────────────────────────────────────────────────

  @doc """
  Create a new invite.
  """
  def create_invite(email, tenant_id, role, invited_by) do
    case @gleam_invite.create(email, tenant_id, role, invited_by) do
      {:ok, invite} -> {:ok, gleam_invite_to_map(invite)}
      {:error, :invalid_email} -> {:error, :invalid_email}
      {:error, _} -> {:error, :invite_creation_failed}
    end
  end

  @doc """
  Check if an invite is valid (pending and not expired).
  """
  def is_invite_valid?(invite) do
    gleam_invite = map_to_gleam_invite(invite)
    @gleam_invite.is_valid(gleam_invite)
  end

  @doc """
  Mark an invite as accepted.
  """
  def accept_invite(invite) do
    gleam_invite = map_to_gleam_invite(invite)
    accepted = @gleam_invite.mark_accepted(gleam_invite)
    gleam_invite_to_map(accepted)
  end

  @doc """
  Mark an invite as cancelled.
  """
  def cancel_invite(invite) do
    gleam_invite = map_to_gleam_invite(invite)
    cancelled = @gleam_invite.mark_cancelled(gleam_invite)
    gleam_invite_to_map(cancelled)
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Token Functions
  # ─────────────────────────────────────────────────────────────────────────────

  @doc """
  Create a document access token.
  """
  def create_document_token(user_id, tenant_id, document_id, scopes, secret) do
    config = @gleam_token.default_config(secret)

    @gleam_token.create_document_token(user_id, tenant_id, document_id, scopes, config)
  end

  @doc """
  Verify a token and extract claims.
  """
  def verify_token(token, secret) do
    case @gleam_token.verify(token, secret) do
      {:ok, claims} -> {:ok, gleam_claims_to_map(claims)}
      {:error, :invalid_signature} -> {:error, :invalid_signature}
      {:error, :token_expired} -> {:error, :token_expired}
      {:error, :malformed_token} -> {:error, :malformed_token}
      {:error, :missing_claims} -> {:error, :missing_claims}
      {:error, _} -> {:error, :token_verification_failed}
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Type Conversions: Gleam -> Elixir
  # ─────────────────────────────────────────────────────────────────────────────

  defp gleam_user_to_map(
         {:user, id, email, password_hash, display_name, github_id, created_at, updated_at}
       ) do
    %{
      id: id,
      email: email,
      password_hash: password_hash,
      display_name: display_name,
      github_id: unwrap_option(github_id),
      created_at: created_at,
      updated_at: updated_at
    }
  end

  defp gleam_tenant_to_map({:tenant, id, name, slug, created_at, updated_at}) do
    %{
      id: id,
      name: name,
      slug: slug,
      created_at: created_at,
      updated_at: updated_at
    }
  end

  defp gleam_membership_to_map({:membership, user_id, tenant_id, role, joined_at}) do
    %{
      user_id: user_id,
      tenant_id: tenant_id,
      role: role,
      joined_at: joined_at
    }
  end

  defp gleam_session_to_map(
         {:session, id, user_id, tenant_id, created_at, expires_at, last_active_at}
       ) do
    %{
      id: id,
      user_id: user_id,
      tenant_id: tenant_id,
      created_at: created_at,
      expires_at: expires_at,
      last_active_at: last_active_at
    }
  end

  defp gleam_invite_to_map(
         {:invite, id, token, email, tenant_id, role, invited_by, status, created_at, expires_at}
       ) do
    %{
      id: id,
      token: token,
      email: email,
      tenant_id: tenant_id,
      role: role,
      invited_by: invited_by,
      status: status,
      created_at: created_at,
      expires_at: expires_at
    }
  end

  defp gleam_claims_to_map(
         {:token_claims, user_id, tenant_id, document_id, scopes, iat, exp, token_id}
       ) do
    %{
      user_id: user_id,
      tenant_id: tenant_id,
      document_id: document_id,
      scopes: scopes,
      iat: iat,
      exp: exp,
      token_id: unwrap_option(token_id)
    }
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Type Conversions: Elixir -> Gleam
  # ─────────────────────────────────────────────────────────────────────────────

  defp map_to_gleam_user(user) do
    github_id = wrap_option(Map.get(user, :github_id))

    {:user, user.id, user.email, user.password_hash, user.display_name, github_id,
     user.created_at, user.updated_at}
  end

  defp map_to_gleam_session(session) do
    {:session, session.id, session.user_id, session.tenant_id, session.created_at,
     session.expires_at, session.last_active_at}
  end

  defp map_to_gleam_invite(invite) do
    {:invite, invite.id, invite.token, invite.email, invite.tenant_id, invite.role,
     invite.invited_by, invite.status, invite.created_at, invite.expires_at}
  end

  # Gleam Option type: {:some, value} or :none
  defp unwrap_option({:some, value}), do: value
  defp unwrap_option(:none), do: nil

  defp wrap_option(nil), do: :none
  defp wrap_option(value), do: {:some, value}
end
