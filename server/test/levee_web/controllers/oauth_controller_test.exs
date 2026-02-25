defmodule LeveeWeb.OAuthControllerTest do
  use LeveeWeb.ConnCase

  describe "request/2" do
    test "returns 404 for unknown provider", %{conn: conn} do
      conn = get(conn, "/auth/unknown")
      assert json_response(conn, 404)["error"]["code"] == "unknown_provider"
    end
  end

  describe "callback/2" do
    test "returns 401 when provider returns error", %{conn: conn} do
      conn =
        get(conn, "/auth/github/callback", %{
          "error" => "access_denied",
          "error_description" => "User denied access"
        })

      body = json_response(conn, 401)
      assert body["error"]["code"] == "oauth_failed"
      assert body["error"]["message"] == "User denied access"
    end

    test "returns 401 when provider returns error without description", %{conn: conn} do
      conn = get(conn, "/auth/github/callback", %{"error" => "access_denied"})

      body = json_response(conn, 401)
      assert body["error"]["code"] == "oauth_failed"
      assert body["error"]["message"] == "access_denied"
    end
  end
end
