defmodule LeveeWeb.Plugs.AdminAuth do
  @moduledoc """
  Authentication plug for admin API routes.

  Validates Bearer tokens against the LEVEE_ADMIN_KEY environment variable.
  """

  import Plug.Conn

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    with {:ok, token} <- extract_token(conn),
         {:ok, admin_key} <- get_admin_key(),
         true <- Plug.Crypto.secure_compare(token, admin_key) do
      assign(conn, :admin, true)
    else
      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          401,
          Jason.encode!(%{error: %{code: "unauthorized", message: "Invalid admin key"}})
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

  defp get_admin_key do
    case System.get_env("LEVEE_ADMIN_KEY") do
      nil -> :error
      "" -> :error
      key -> {:ok, key}
    end
  end
end
