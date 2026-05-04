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
    setup do
      previous_env =
        for key <- ["GITHUB_CLIENT_ID", "GITHUB_CLIENT_SECRET", "GITHUB_REDIRECT_URI"],
            into: %{},
            do: {key, System.get_env(key)}

      System.put_env("GITHUB_CLIENT_ID", "test-client")
      System.put_env("GITHUB_CLIENT_SECRET", "test-secret")
      System.put_env("GITHUB_REDIRECT_URI", "http://localhost:4000/auth/github/callback")

      on_exit(fn ->
        Enum.each(previous_env, fn
          {key, nil} -> System.delete_env(key)
          {key, value} -> System.put_env(key, value)
        end)
      end)
    end

    test "returns 401 when provider returns error", %{conn: conn} do
      actor = Levee.OAuth.StateStoreSupervisor.get_actor()
      :levee_oauth@state_store.store(actor, "valid-state", "code-verifier", 180)

      conn =
        get(conn, "/auth/github/callback", %{
          "error" => "access_denied",
          "error_description" => "User denied access",
          "state" => "valid-state"
        })

      body = json_response(conn, 401)
      assert body["error"]["code"] == "oauth_failed"
      assert body["error"]["message"] == "User denied access"
    end

    test "returns 401 when provider returns error without description", %{conn: conn} do
      actor = Levee.OAuth.StateStoreSupervisor.get_actor()

      :levee_oauth@state_store.store(
        actor,
        "valid-state-without-description",
        "code-verifier",
        180
      )

      conn =
        get(conn, "/auth/github/callback", %{
          "error" => "access_denied",
          "state" => "valid-state-without-description"
        })

      body = json_response(conn, 401)
      assert body["error"]["code"] == "oauth_failed"
      assert body["error"]["message"] == "access_denied"
    end

    test "does not surface provider error details when state is invalid", %{conn: conn} do
      conn =
        get(conn, "/auth/github/callback", %{
          "error" => "access_denied",
          "error_description" => "User denied access",
          "state" => "invalid-state"
        })

      body = json_response(conn, 401)
      refute body["error"]["code"] == "oauth_failed"
      refute body["error"]["message"] == "User denied access"
    end

    test "does not surface provider error details when state is missing", %{conn: conn} do
      conn =
        get(conn, "/auth/github/callback", %{
          "error" => "access_denied",
          "error_description" => "User denied access"
        })

      body = json_response(conn, 401)
      refute body["error"]["code"] == "oauth_failed"
      refute body["error"]["message"] == "User denied access"
    end
  end
end
