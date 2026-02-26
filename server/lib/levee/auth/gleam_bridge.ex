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
  @gleam_session_store :session_store

  # Tell compiler these modules will exist at runtime
  @compile {:no_warn_undefined,
            [
              :password,
              :user,
              :tenant,
              :session,
              :invite,
              :token,
              :scopes,
              :session_store
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
  # Session Store Functions (Gleam actor)
  # ─────────────────────────────────────────────────────────────────────────────

  defp get_session_store_actor do
    Levee.Auth.SessionStoreSupervisor.get_actor()
  end

  @doc """
  Store a user in the session store.
  """
  def store_user(user) do
    actor = get_session_store_actor()
    gleam_user = map_to_gleam_user(user)
    @gleam_session_store.store_user(actor, gleam_user)
  end

  @doc """
  Get a user by ID from the session store.
  Returns `{:ok, user_map}` or `:error`.
  """
  def get_user(user_id) do
    actor = get_session_store_actor()

    case @gleam_session_store.get_user(actor, user_id) do
      {:ok, gleam_user} -> {:ok, gleam_user_to_map(gleam_user)}
      {:error, _} -> :error
    end
  end

  @doc """
  Find a user by email.
  Returns `{:ok, user_map}` or `:error`.
  """
  def find_user_by_email(email) do
    actor = get_session_store_actor()

    case @gleam_session_store.find_user_by_email(actor, email) do
      {:ok, gleam_user} -> {:ok, gleam_user_to_map(gleam_user)}
      {:error, _} -> :error
    end
  end

  @doc """
  Find a user by GitHub ID.
  Returns `{:ok, user_map}` or `:error`.
  """
  def find_user_by_github_id(github_id) do
    actor = get_session_store_actor()

    case @gleam_session_store.find_user_by_github_id(actor, github_id) do
      {:ok, gleam_user} -> {:ok, gleam_user_to_map(gleam_user)}
      {:error, _} -> :error
    end
  end

  @doc """
  Get the number of stored users.
  """
  def user_count do
    actor = get_session_store_actor()
    @gleam_session_store.user_count(actor)
  end

  @doc """
  Store a session in the session store.
  """
  def store_session(session) do
    actor = get_session_store_actor()
    gleam_session = map_to_gleam_session(session)
    @gleam_session_store.store_session(actor, gleam_session)
  end

  @doc """
  Get a session by ID from the session store.
  Optionally validates the session belongs to the given tenant.
  Returns `{:ok, session_map}` or `:error`.
  """
  def get_session(session_id, tenant_id \\ nil) do
    actor = get_session_store_actor()
    gleam_tenant_id = wrap_option(tenant_id)

    case @gleam_session_store.get_session(actor, session_id, gleam_tenant_id) do
      {:ok, gleam_session} -> {:ok, gleam_session_to_map(gleam_session)}
      {:error, _} -> :error
    end
  end

  @doc """
  Delete a session by ID from the session store.
  """
  def delete_session(session_id) do
    actor = get_session_store_actor()
    @gleam_session_store.delete_session(actor, session_id)
  end

  @doc """
  Clear all users and sessions (test helper).
  """
  def clear_session_store do
    actor = get_session_store_actor()
    @gleam_session_store.clear(actor)
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Type Conversions: Gleam -> Elixir
  # ─────────────────────────────────────────────────────────────────────────────

  defp gleam_user_to_map(
         {:user, id, email, password_hash, display_name, github_id, is_admin, created_at,
          updated_at}
       ) do
    %{
      id: id,
      email: email,
      password_hash: password_hash,
      display_name: display_name,
      github_id: unwrap_option(github_id),
      is_admin: is_admin,
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
    is_admin = Map.get(user, :is_admin, false)

    {:user, user.id, user.email, user.password_hash, user.display_name, github_id, is_admin,
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
