defmodule LeveeWeb.Plugs.AdminSessionAuth do
  @moduledoc """
  Authentication plug for admin session-based routes.

  Validates Bearer tokens as session IDs (like SessionAuth) and additionally
  checks that the authenticated user has admin privileges (is_admin == true).

  Returns 401 for invalid/missing sessions, 403 for non-admin users.
  """

  import Plug.Conn

  alias Levee.Auth.GleamBridge

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    with {:ok, session_id} <- extract_token(conn),
         {:ok, session} <- GleamBridge.get_session(session_id),
         true <- GleamBridge.is_session_valid?(session),
         {:ok, user} <- GleamBridge.get_user(session.user_id),
         true <- user.is_admin do
      conn
      |> assign(:current_user, user)
      |> assign(:current_session, session)
    else
      false ->
        # User exists and session is valid, but user is not admin
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          403,
          Jason.encode!(%{error: %{code: "forbidden", message: "Admin access required"}})
        )
        |> halt()

      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          401,
          Jason.encode!(%{
            error: %{code: "unauthorized", message: "Invalid or expired session"}
          })
        )
        |> halt()
    end
  end

  defp extract_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> {:ok, String.trim(token)}
      _ -> :error
    end
  end
end
