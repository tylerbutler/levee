defmodule LeveeWeb.OAuthController do
  use LeveeWeb, :controller

  plug Ueberauth

  alias Levee.Auth.GleamBridge
  alias Levee.Auth.SessionStore

  @doc """
  Handles the OAuth callback from the provider.

  On success: finds or creates user by GitHub ID, creates a session,
  and redirects to the frontend with the session token.
  """
  def callback(%{assigns: %{ueberauth_auth: auth}} = conn, _params) do
    github_id = to_string(auth.uid)
    email = auth.info.email || ""
    display_name = auth.info.name || auth.info.nickname || ""

    user =
      case SessionStore.find_user_by_github_id(github_id) do
        {:ok, existing_user} ->
          existing_user

        :error ->
          new_user = GleamBridge.create_oauth_user(email, display_name, github_id)

          # Auto-promote first user to admin
          new_user =
            if SessionStore.user_count() == 0 do
              Map.put(new_user, :is_admin, true)
            else
              new_user
            end

          SessionStore.store_user(new_user)
          new_user
      end

    session = GleamBridge.create_session(user.id, nil)
    SessionStore.store_session(session)

    redirect_url = get_redirect_url(conn, session.id)
    redirect(conn, external: redirect_url)
  end

  def callback(%{assigns: %{ueberauth_failure: failure}} = conn, _params) do
    messages =
      failure.errors
      |> Enum.map(& &1.message)
      |> Enum.join(", ")

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{error: %{code: "oauth_failed", message: messages}}))
  end

  defp get_redirect_url(conn, token) do
    redirect_to = conn.params["redirect_url"] || "/admin"
    separator = if String.contains?(redirect_to, "?"), do: "&", else: "?"
    "#{redirect_to}#{separator}token=#{token}"
  end
end
