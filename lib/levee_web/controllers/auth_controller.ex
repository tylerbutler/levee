defmodule LeveeWeb.AuthController do
  use LeveeWeb, :controller

  alias Levee.Auth.GleamBridge
  alias Levee.Auth.SessionStore

  @doc """
  Register a new user.

  POST /api/auth/register
  Body: {email, password, display_name}
  Returns: {user, token}
  """
  def register(conn, %{"email" => email, "password" => password} = params) do
    display_name = Map.get(params, "display_name", "")

    case GleamBridge.create_user(email, password, display_name) do
      {:ok, user} ->
        # Store the user
        SessionStore.store_user(user)

        # Create a session for the new user
        session = GleamBridge.create_session(user.id, nil)
        SessionStore.store_session(session)

        conn
        |> put_status(:created)
        |> json(%{
          user: user_to_json(user),
          token: session.id
        })

      {:error, :invalid_email} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_email", message: "Invalid email format"}})

      {:error, :password_too_short} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          error: %{code: "password_too_short", message: "Password must be at least 8 characters"}
        })

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "registration_failed", message: inspect(reason)}})
    end
  end

  @doc """
  Login with email and password.

  POST /api/auth/login
  Body: {email, password}
  Returns: {user, token}
  """
  # Dummy hash for timing-safe comparison when user not found.
  # This prevents user enumeration via timing attacks.
  @dummy_hash "$pbkdf2-sha256$600000$AAAAAAAAAAAAAAAAAAAAAA==$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

  def login(conn, %{"email" => email, "password" => password}) do
    {user, hash} =
      case SessionStore.find_user_by_email(email) do
        {:ok, user} -> {user, user.password_hash}
        :error -> {nil, @dummy_hash}
      end

    # Always verify password to prevent timing attacks
    password_valid = GleamBridge.verify_password(password, hash)

    case {user, password_valid} do
      {%{} = user, true} ->
        session = GleamBridge.create_session(user.id, nil)
        SessionStore.store_session(session)

        conn
        |> put_status(:ok)
        |> json(%{
          user: user_to_json(user),
          token: session.id
        })

      _ ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: %{code: "invalid_credentials", message: "Invalid email or password"}})
    end
  end

  @doc """
  Get the current authenticated user.

  GET /api/auth/me
  Requires: Authorization header with session token
  Returns: {user}
  """
  def me(conn, _params) do
    # current_user is set by SessionAuth plug
    user = conn.assigns.current_user

    conn
    |> put_status(:ok)
    |> json(%{user: user_to_json(user)})
  end

  @doc """
  Logout the current user.

  POST /api/auth/logout
  Requires: Authorization header with session token
  Returns: {message: "logged out"}
  """
  def logout(conn, _params) do
    # current_session is set by SessionAuth plug
    session = conn.assigns.current_session
    SessionStore.delete_session(session.id)

    conn
    |> put_status(:ok)
    |> json(%{message: "logged out"})
  end

  # Private helpers

  defp user_to_json(user) do
    %{
      id: user.id,
      email: user.email,
      display_name: user.display_name,
      created_at: user.created_at
    }
  end
end
