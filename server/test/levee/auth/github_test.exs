defmodule Levee.Auth.GitHubTest do
  use ExUnit.Case, async: true

  alias Levee.Auth.GitHub

  describe "check_team_membership/4" do
    test "returns {:ok, :active} when user is an active member" do
      Req.Test.stub(GitHub, fn conn ->
        assert conn.method == "GET"

        assert conn.request_path ==
                 "/orgs/my-org/teams/engineering/memberships/alice"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"state" => "active", "role" => "member"}))
      end)

      assert {:ok, :active} =
               GitHub.check_team_membership("test-token", "alice", "my-org", "engineering",
                 req_options: [plug: {Req.Test, GitHub}]
               )
    end

    test "returns {:ok, :not_member} when user has pending invitation" do
      Req.Test.stub(GitHub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"state" => "pending", "role" => "member"}))
      end)

      assert {:ok, :not_member} =
               GitHub.check_team_membership("test-token", "alice", "my-org", "engineering",
                 req_options: [plug: {Req.Test, GitHub}]
               )
    end

    test "returns {:ok, :not_member} when user is not a member (404)" do
      Req.Test.stub(GitHub, fn conn ->
        Plug.Conn.send_resp(conn, 404, "")
      end)

      assert {:ok, :not_member} =
               GitHub.check_team_membership("test-token", "alice", "my-org", "engineering",
                 req_options: [plug: {Req.Test, GitHub}]
               )
    end

    test "returns error on unexpected status" do
      Req.Test.stub(GitHub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(403, Jason.encode!(%{"message" => "Forbidden"}))
      end)

      assert {:error, {:unexpected_status, 403}} =
               GitHub.check_team_membership("test-token", "alice", "my-org", "engineering",
                 req_options: [plug: {Req.Test, GitHub}]
               )
    end

    test "sends correct authorization header" do
      Req.Test.stub(GitHub, fn conn ->
        auth_header =
          conn
          |> Plug.Conn.get_req_header("authorization")
          |> List.first()

        assert auth_header == "Bearer my-secret-token"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"state" => "active"}))
      end)

      GitHub.check_team_membership(
        "my-secret-token",
        "alice",
        "my-org",
        "engineering",
        req_options: [plug: {Req.Test, GitHub}]
      )
    end
  end

  describe "member_of_any_team?/4" do
    test "returns :denied for empty team list" do
      assert :denied = GitHub.member_of_any_team?("token", "alice", [])
    end

    test "returns :ok when user is a member of first team" do
      Req.Test.stub(GitHub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"state" => "active"}))
      end)

      teams = [{"my-org", "team-a"}, {"my-org", "team-b"}]

      assert :ok =
               GitHub.member_of_any_team?("token", "alice", teams,
                 req_options: [plug: {Req.Test, GitHub}]
               )
    end

    test "returns :ok when user is a member of second team but not first" do
      call_count = :counters.new(1, [:atomics])

      Req.Test.stub(GitHub, fn conn ->
        :counters.add(call_count, 1, 1)
        count = :counters.get(call_count, 1)

        if count == 1 do
          Plug.Conn.send_resp(conn, 404, "")
        else
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, Jason.encode!(%{"state" => "active"}))
        end
      end)

      teams = [{"my-org", "team-a"}, {"my-org", "team-b"}]

      assert :ok =
               GitHub.member_of_any_team?("token", "alice", teams,
                 req_options: [plug: {Req.Test, GitHub}]
               )
    end

    test "returns :denied when user is not a member of any team" do
      Req.Test.stub(GitHub, fn conn ->
        Plug.Conn.send_resp(conn, 404, "")
      end)

      teams = [{"my-org", "team-a"}, {"my-org", "team-b"}]

      assert :denied =
               GitHub.member_of_any_team?("token", "alice", teams,
                 req_options: [plug: {Req.Test, GitHub}]
               )
    end

    test "returns :denied when API returns errors (fail closed)" do
      Req.Test.stub(GitHub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(500, Jason.encode!(%{"message" => "Internal Server Error"}))
      end)

      teams = [{"my-org", "team-a"}]

      assert :denied =
               GitHub.member_of_any_team?("token", "alice", teams,
                 req_options: [plug: {Req.Test, GitHub}]
               )
    end
  end
end
