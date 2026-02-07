defmodule LeveeWeb.AuthControllerTest do
  use LeveeWeb.ConnCase

  alias Levee.Auth.GleamBridge
  alias Levee.Auth.SessionStore

  setup do
    # Clear the session store before each test
    SessionStore.clear()
    :ok
  end

  describe "POST /api/auth/register" do
    test "creates a new user with valid data", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/auth/register", %{
          email: "newuser@example.com",
          password: "secure_password_123",
          display_name: "New User"
        })

      assert %{"user" => user, "token" => token} = json_response(conn, 201)
      assert user["email"] == "newuser@example.com"
      assert user["display_name"] == "New User"
      assert String.starts_with?(user["id"], "usr_")
      assert is_binary(token)
      # Token is a session ID (ses_ prefix)
      assert String.starts_with?(token, "ses_")
    end

    test "returns error for invalid email", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/auth/register", %{
          email: "not-an-email",
          password: "secure_password_123",
          display_name: "Test"
        })

      assert %{"error" => error} = json_response(conn, 422)
      assert error["code"] == "invalid_email"
    end

    test "returns error for short password", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/auth/register", %{
          email: "test@example.com",
          password: "short",
          display_name: "Test"
        })

      assert %{"error" => error} = json_response(conn, 422)
      assert error["code"] == "password_too_short"
    end
  end

  describe "POST /api/auth/login" do
    setup do
      # Create a user to login with and store it
      {:ok, user} =
        GleamBridge.create_user("login@example.com", "correct_password", "Login User")

      SessionStore.store_user(user)

      {:ok, user: user}
    end

    test "returns token for valid credentials", %{conn: conn, user: user} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/auth/login", %{
          email: "login@example.com",
          password: "correct_password"
        })

      assert %{"user" => returned_user, "token" => token} = json_response(conn, 200)
      assert returned_user["id"] == user.id
      assert returned_user["email"] == "login@example.com"
      assert is_binary(token)
    end

    test "returns error for wrong password", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/auth/login", %{
          email: "login@example.com",
          password: "wrong_password"
        })

      assert %{"error" => error} = json_response(conn, 401)
      assert error["code"] == "invalid_credentials"
    end

    test "returns error for non-existent user", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/auth/login", %{
          email: "nobody@example.com",
          password: "any_password"
        })

      assert %{"error" => error} = json_response(conn, 401)
      assert error["code"] == "invalid_credentials"
    end
  end

  describe "GET /api/auth/me" do
    setup do
      {:ok, user} =
        GleamBridge.create_user("me@example.com", "password123", "Me User")

      SessionStore.store_user(user)

      # Create a session for the user
      session = GleamBridge.create_session(user.id, nil)
      SessionStore.store_session(session)

      {:ok, user: user, session: session}
    end

    test "returns current user with valid session", %{conn: conn, user: user, session: session} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{session.id}")
        |> get("/api/auth/me")

      assert %{"user" => returned_user} = json_response(conn, 200)
      assert returned_user["id"] == user.id
      assert returned_user["email"] == "me@example.com"
    end

    test "returns error without authorization", %{conn: conn} do
      conn = get(conn, "/api/auth/me")

      assert json_response(conn, 401)
    end
  end

  describe "POST /api/auth/logout" do
    setup do
      {:ok, user} =
        GleamBridge.create_user("logout@example.com", "password123", "Logout User")

      SessionStore.store_user(user)

      session = GleamBridge.create_session(user.id, nil)
      SessionStore.store_session(session)

      {:ok, user: user, session: session}
    end

    test "invalidates the session", %{conn: conn, session: session} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{session.id}")
        |> post("/api/auth/logout")

      assert json_response(conn, 200)

      # Subsequent requests should fail
      conn2 =
        build_conn()
        |> put_req_header("authorization", "Bearer #{session.id}")
        |> get("/api/auth/me")

      assert json_response(conn2, 401)
    end
  end
end
