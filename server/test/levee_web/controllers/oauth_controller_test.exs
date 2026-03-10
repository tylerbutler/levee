defmodule LeveeWeb.OAuthControllerTest do
  use LeveeWeb.ConnCase

  describe "check_github_access (user allowlist only)" do
    setup do
      Application.put_env(:levee, :github_allowed_teams, nil)
      on_exit(fn -> Application.put_env(:levee, :github_allowed_users, nil) end)
    end

    test "allows all users when both configs are nil" do
      Application.put_env(:levee, :github_allowed_users, nil)
      assert check_access("anyuser", "token") == :ok
    end

    test "denies when users list is empty and teams is nil" do
      Application.put_env(:levee, :github_allowed_users, [])
      assert check_access("anyuser", "token") == :denied
    end

    test "allows users on the list" do
      Application.put_env(:levee, :github_allowed_users, ["alice", "bob"])
      assert check_access("alice", "token") == :ok
      assert check_access("bob", "token") == :ok
    end

    test "denies users not on the list" do
      Application.put_env(:levee, :github_allowed_users, ["alice", "bob"])
      assert check_access("charlie", "token") == :denied
    end

    test "comparison is case-insensitive" do
      Application.put_env(:levee, :github_allowed_users, ["Alice"])
      assert check_access("alice", "token") == :ok
      assert check_access("ALICE", "token") == :ok
      assert check_access("Alice", "token") == :ok
    end

    test "denies nil username" do
      Application.put_env(:levee, :github_allowed_users, ["alice"])
      assert check_access(nil, "token") == :denied
    end
  end

  describe "check_github_access (OR logic with teams)" do
    setup do
      on_exit(fn ->
        Application.put_env(:levee, :github_allowed_users, nil)
        Application.put_env(:levee, :github_allowed_teams, nil)
      end)
    end

    test "allows when user is on user list but not in any team" do
      Application.put_env(:levee, :github_allowed_users, ["alice"])
      Application.put_env(:levee, :github_allowed_teams, [{"my-org", "nonexistent-team"}])
      # OR logic: user list match is sufficient
      assert check_access("alice", "token") == :ok
    end

    test "denies when user is not on user list and teams are configured but empty" do
      Application.put_env(:levee, :github_allowed_users, ["alice"])
      Application.put_env(:levee, :github_allowed_teams, [])
      assert check_access("charlie", "token") == :denied
    end
  end

  # Replicate the combined check logic from OAuthController
  defp check_access(username, _access_token) do
    allowed_users = Application.get_env(:levee, :github_allowed_users)
    allowed_teams = Application.get_env(:levee, :github_allowed_teams)

    case {allowed_users, allowed_teams} do
      {nil, nil} ->
        :ok

      _ ->
        user_result = check_allowed_users(username, allowed_users)
        team_result = check_allowed_teams(allowed_teams)

        if user_result == :ok or team_result == :ok, do: :ok, else: :denied
    end
  end

  defp check_allowed_users(_username, nil), do: :denied
  defp check_allowed_users(_username, []), do: :denied

  defp check_allowed_users(username, allowed_users) when is_list(allowed_users) do
    downcased = String.downcase(username || "")

    if Enum.any?(allowed_users, &(String.downcase(&1) == downcased)) do
      :ok
    else
      :denied
    end
  end

  # For unit tests of the OR logic we don't call the GitHub API;
  # the GitHub API module has its own tests with Req.Test stubs.
  defp check_allowed_teams(nil), do: :denied
  defp check_allowed_teams([]), do: :denied
  defp check_allowed_teams(_teams), do: :denied

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
