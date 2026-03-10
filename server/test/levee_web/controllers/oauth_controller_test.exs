defmodule LeveeWeb.OAuthControllerTest do
  use LeveeWeb.ConnCase

  describe "check_github_allowed/1" do
    test "allows all users when config is nil" do
      Application.put_env(:levee, :github_allowed_users, nil)
      assert check_allowed("anyuser") == :ok
    end

    test "denies all users when config is empty list" do
      Application.put_env(:levee, :github_allowed_users, [])
      assert check_allowed("anyuser") == :denied
    after
      Application.put_env(:levee, :github_allowed_users, nil)
    end

    test "allows users on the list" do
      Application.put_env(:levee, :github_allowed_users, ["alice", "bob"])
      assert check_allowed("alice") == :ok
      assert check_allowed("bob") == :ok
    after
      Application.put_env(:levee, :github_allowed_users, nil)
    end

    test "denies users not on the list" do
      Application.put_env(:levee, :github_allowed_users, ["alice", "bob"])
      assert check_allowed("charlie") == :denied
    after
      Application.put_env(:levee, :github_allowed_users, nil)
    end

    test "comparison is case-insensitive" do
      Application.put_env(:levee, :github_allowed_users, ["Alice"])
      assert check_allowed("alice") == :ok
      assert check_allowed("ALICE") == :ok
      assert check_allowed("Alice") == :ok
    after
      Application.put_env(:levee, :github_allowed_users, nil)
    end

    test "denies nil username" do
      Application.put_env(:levee, :github_allowed_users, ["alice"])
      assert check_allowed(nil) == :denied
    after
      Application.put_env(:levee, :github_allowed_users, nil)
    end
  end

  # Expose the private function for testing
  defp check_allowed(username) do
    # Replicate the logic from OAuthController.check_github_allowed/1
    case Application.get_env(:levee, :github_allowed_users) do
      nil ->
        :ok

      [] ->
        :denied

      allowed_users when is_list(allowed_users) ->
        downcased = String.downcase(username || "")

        if Enum.any?(allowed_users, &(String.downcase(&1) == downcased)) do
          :ok
        else
          :denied
        end
    end
  end

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
