defmodule LeveeWeb.Plugs.SessionAuth do
  @moduledoc """
  Authentication plug for session-based auth routes.

  Validates Bearer tokens as session IDs against the SessionStore.
  Used for auth endpoints like /api/auth/me and /api/auth/logout
  that require a valid session but not a JWT with tenant/document context.
  """

  import Plug.Conn

  alias Levee.Auth.SessionStore
  alias Levee.Auth.GleamBridge

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    with {:ok, session_id} <- extract_token(conn),
         {:ok, session} <- SessionStore.get_session(session_id),
         true <- GleamBridge.is_session_valid?(session),
         {:ok, user} <- SessionStore.get_user(session.user_id) do
      conn
      |> assign(:current_user, user)
      |> assign(:current_session, session)
    else
      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          401,
          Jason.encode!(%{error: %{code: "unauthorized", message: "Invalid or expired session"}})
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
