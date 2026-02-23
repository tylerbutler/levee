defmodule LeveeWeb.OAuthControllerTest do
  use LeveeWeb.ConnCase

  alias Levee.Auth.SessionStore

  setup do
    SessionStore.clear()
    :ok
  end

  describe "GET /auth/github/callback" do
    test "creates a new user and redirects with token on successful auth", %{conn: conn} do
      auth = %Ueberauth.Auth{
        uid: "12345",
        provider: :github,
        info: %Ueberauth.Auth.Info{
          email: "ghuser@example.com",
          name: "GitHub User",
          nickname: "ghuser"
        },
        credentials: %Ueberauth.Auth.Credentials{}
      }

      conn =
        conn
        |> assign(:ueberauth_auth, auth)
        |> get("/auth/github/callback")

      assert redirected_to(conn) =~ "/admin?token=ses_"
    end

    test "finds existing user on repeat login", %{conn: _conn} do
      auth = %Ueberauth.Auth{
        uid: "12345",
        provider: :github,
        info: %Ueberauth.Auth.Info{
          email: "ghuser@example.com",
          name: "GitHub User",
          nickname: "ghuser"
        },
        credentials: %Ueberauth.Auth.Credentials{}
      }

      # First login — creates the user
      conn1 =
        build_conn()
        |> assign(:ueberauth_auth, auth)
        |> get("/auth/github/callback")

      assert redirected_to(conn1) =~ "token=ses_"

      # Second login — same GitHub user
      conn2 =
        build_conn()
        |> assign(:ueberauth_auth, auth)
        |> get("/auth/github/callback")

      assert redirected_to(conn2) =~ "token=ses_"

      # Should still be only one user with this github_id
      {:ok, user} = SessionStore.find_user_by_github_id("12345")
      assert user.email == "ghuser@example.com"
    end

    test "uses redirect_url param when provided", %{conn: conn} do
      auth = %Ueberauth.Auth{
        uid: "99999",
        provider: :github,
        info: %Ueberauth.Auth.Info{
          email: "redirect@example.com",
          name: "Redirect User",
          nickname: "redir"
        },
        credentials: %Ueberauth.Auth.Credentials{}
      }

      conn =
        conn
        |> assign(:ueberauth_auth, auth)
        |> get("/auth/github/callback", %{"redirect_url" => "http://localhost:3000/app"})

      location = redirected_to(conn)
      assert location =~ "http://localhost:3000/app?token=ses_"
    end

    test "returns error on OAuth failure", %{conn: conn} do
      # Without valid CSRF state, ueberauth sets its own failure
      conn = get(conn, "/auth/github/callback", %{"code" => "invalid"})

      assert %{"error" => error} = json_response(conn, 401)
      assert error["code"] == "oauth_failed"
      assert is_binary(error["message"])
    end
  end
end
