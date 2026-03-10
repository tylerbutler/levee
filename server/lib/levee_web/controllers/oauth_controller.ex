defmodule LeveeWeb.OAuthController do
  use LeveeWeb, :controller

  alias Levee.Auth.GleamBridge

  @compile {:no_warn_undefined, [:levee_oauth]}

  @doc """
  Phase 1: Redirect the user to the OAuth provider's authorization page.
  """
  def request(conn, %{"provider" => provider}) do
    actor = Levee.OAuth.StateStoreSupervisor.get_actor()

    case :levee_oauth.begin_auth(provider, actor) do
      {:ok, url} ->
        redirect(conn, external: url)

      {:error, {:unknown_provider, _name}} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          404,
          Jason.encode!(%{
            error: %{code: "unknown_provider", message: "Unknown auth provider: #{provider}"}
          })
        )

      {:error, {:config_missing, variable}} ->
        require Logger
        Logger.error("OAuth not configured: missing #{variable}")

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          500,
          Jason.encode!(%{
            error: %{code: "oauth_not_configured", message: "OAuth is not configured"}
          })
        )

      {:error, reason} ->
        require Logger
        Logger.error("OAuth begin_auth failed: #{inspect(reason)}")

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          500,
          Jason.encode!(%{
            error: %{code: "oauth_error", message: "Failed to start authentication"}
          })
        )
    end
  end

  @doc """
  Phase 2: Handle the OAuth callback from the provider.
  """
  def callback(conn, %{"provider" => provider, "code" => code, "state" => state}) do
    actor = Levee.OAuth.StateStoreSupervisor.get_actor()

    case :levee_oauth.complete_auth(provider, code, state, actor) do
      {:ok, auth} ->
        handle_successful_auth(conn, auth)

      {:error, {:vestibule_error, :state_mismatch}} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          401,
          Jason.encode!(%{
            error: %{code: "state_mismatch", message: "Authentication failed, please try again"}
          })
        )

      {:error, {:vestibule_error, {:code_exchange_failed, _reason}}} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          401,
          Jason.encode!(%{
            error: %{code: "auth_failed", message: "Authentication failed, please try again"}
          })
        )

      {:error, {:vestibule_error, {:user_info_failed, _reason}}} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          502,
          Jason.encode!(%{
            error: %{code: "provider_error", message: "Could not fetch profile from provider"}
          })
        )

      {:error, :state_store_unavailable} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          401,
          Jason.encode!(%{
            error: %{code: "state_invalid", message: "Authentication failed, please try again"}
          })
        )

      {:error, reason} ->
        require Logger
        Logger.error("OAuth complete_auth failed: #{inspect(reason)}")

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          401,
          Jason.encode!(%{error: %{code: "auth_failed", message: "Authentication failed"}})
        )
    end
  end

  def callback(conn, %{"provider" => _provider, "error" => error_code} = params) do
    message = Map.get(params, "error_description", error_code)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{error: %{code: "oauth_failed", message: message}}))
  end

  defp handle_successful_auth(conn, auth) do
    # Extract fields from vestibule Auth record
    # Auth is a Gleam record: {:auth, uid, provider, info, credentials, extra}
    {_tag, uid, _provider, info, _credentials, _extra} = auth
    github_id = uid

    # Extract user info from vestibule UserInfo record
    # UserInfo: {:user_info, name, email, nickname, image, description, urls}
    {_tag, name, email, nickname, _image, _description, _urls} = info
    github_username = unwrap_option(nickname)
    display_name = unwrap_option(name) || github_username || ""
    email_str = unwrap_option(email) || ""

    case check_github_allowed(github_username) do
      :ok ->
        user =
          case GleamBridge.find_user_by_github_id(github_id) do
            {:ok, existing_user} ->
              existing_user

            :error ->
              new_user = GleamBridge.create_oauth_user(email_str, display_name, github_id)

              # Auto-promote first user to admin
              new_user =
                if GleamBridge.user_count() == 0 do
                  Map.put(new_user, :is_admin, true)
                else
                  new_user
                end

              GleamBridge.store_user(new_user)
              new_user
          end

        session = GleamBridge.create_session(user.id, nil)
        GleamBridge.store_session(session)

        redirect_url = get_redirect_url(conn, session.id)
        redirect(conn, external: redirect_url)

      :denied ->
        require Logger
        Logger.warning("GitHub login denied for user not on allow list: #{github_username}")
        redirect(conn, to: "/admin?error=not_authorized")
    end
  end

  defp get_redirect_url(conn, token) do
    redirect_to = conn.params["redirect_url"] || "/admin"
    separator = if String.contains?(redirect_to, "?"), do: "&", else: "?"
    "#{redirect_to}#{separator}token=#{token}"
  end

  # Check if a GitHub username is on the allow list.
  # Returns :ok if allowed, :denied if not.
  defp check_github_allowed(username) do
    case Application.get_env(:levee, :github_allowed_users) do
      nil ->
        :ok

      [] ->
        :denied

      allowed_users when is_list(allowed_users) ->
        # GitHub usernames are case-insensitive, so we downcase both sides
        # to avoid config mismatches (e.g. "TylerBu" vs "tylerbu").
        downcased = String.downcase(username || "")

        if Enum.any?(allowed_users, &(String.downcase(&1) == downcased)) do
          :ok
        else
          :denied
        end
    end
  end

  # Gleam Option type: {:some, value} or :none
  defp unwrap_option({:some, value}), do: value
  defp unwrap_option(:none), do: nil
end
