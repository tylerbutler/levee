# GitHub OAuth via Ueberauth — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add GitHub OAuth login to Levee using ueberauth, available for both admin UI and end-user auth, coexisting with email/password.

**Architecture:** Ueberauth handles the OAuth redirect/callback flow as a Plug. A new `OAuthController` delegates to it, then finds-or-creates a user by GitHub ID via the Gleam `user` module and GleamBridge, creates a session, and redirects with the token. The Gleam `User` type gains an optional `github_id` field.

**Tech Stack:** Elixir/Phoenix (ueberauth, ueberauth_github), Gleam (levee_auth user module)

---

## Task 1: Add ueberauth dependencies

**Files:**
- Modify: `server/mix.exs:40-56` (deps function)

**Step 1: Add deps to mix.exs**

In the `deps` function, add after the `{:cors_plug, "~> 3.0"}` line:

```elixir
      # OAuth authentication
      {:ueberauth, "~> 0.10"},
      {:ueberauth_github, "~> 0.8"},
```

**Step 2: Install dependencies**

Run: `cd server && mix deps.get`
Expected: Dependencies fetched successfully

**Step 3: Verify compilation**

Run: `cd server && mix compile`
Expected: Compiles without errors

**Step 4: Commit**

```bash
git add server/mix.exs server/mix.lock
git commit -m "feat(auth): add ueberauth and ueberauth_github dependencies"
```

---

## Task 2: Configure ueberauth

**Files:**
- Modify: `server/config/config.exs:33` (after phoenix json_library config)
- Modify: `server/config/runtime.exs:23` (after PORT config, before prod block)
- Modify: `server/config/test.exs:29` (end of file)

**Step 1: Add ueberauth provider config to config.exs**

After the line `config :phoenix, :json_library, Jason`, add:

```elixir

# Configure Ueberauth for OAuth
config :ueberauth, Ueberauth,
  providers: [
    github: {Ueberauth.Strategy.Github, [default_scope: "user:email"]}
  ]
```

**Step 2: Add GitHub credentials to runtime.exs**

After the `http: [port: ...]` line (line 23) and before the `if config_env() == :prod do` block, add:

```elixir

# Configure GitHub OAuth credentials from environment
if github_client_id = System.get_env("GITHUB_CLIENT_ID") do
  config :ueberauth, Ueberauth.Strategy.Github.OAuth,
    client_id: github_client_id,
    client_secret: System.get_env("GITHUB_CLIENT_SECRET")
end
```

**Step 3: Add test config for ueberauth**

At the end of `server/config/test.exs`, add:

```elixir

# Disable ueberauth in tests (we mock the callbacks)
config :ueberauth, Ueberauth.Strategy.Github.OAuth,
  client_id: "test_client_id",
  client_secret: "test_client_secret"
```

**Step 4: Verify compilation**

Run: `cd server && mix compile`
Expected: Compiles without errors

**Step 5: Commit**

```bash
git add server/config/config.exs server/config/runtime.exs server/config/test.exs
git commit -m "feat(auth): configure ueberauth GitHub OAuth provider"
```

---

## Task 3: Add `github_id` to Gleam User type

**Files:**
- Modify: `server/levee_auth/src/user.gleam:1-190`
- Modify: `server/levee_auth/test/user_test.gleam:1-185`

**Step 1: Update User type**

In `server/levee_auth/src/user.gleam`, add `gleam/option` import at the top (after `import gleam/float`):

```gleam
import gleam/option.{type Option, None, Some}
```

Update the `User` type (line 16-31) to include `github_id`:

```gleam
pub type User {
  User(
    id: String,
    email: String,
    password_hash: String,
    display_name: String,
    github_id: Option(String),
    created_at: Int,
    updated_at: Int,
  )
}
```

**Step 2: Update `create` function**

In the `Ok(User(...))` return (line 80-88), add `github_id: None`:

```gleam
  Ok(User(
    id: id,
    email: email,
    password_hash: password_hash,
    display_name: name,
    github_id: None,
    created_at: now,
    updated_at: now,
  ))
```

**Step 3: Add `create_oauth` function**

After the `create` function (after line 88), add:

```gleam
/// Create a new user from an OAuth provider (no password required).
pub fn create_oauth(
  email email: String,
  display_name display_name: String,
  github_id github_id: String,
) -> User {
  let now = now_unix()
  let id = generate_id("usr")

  let name = case display_name {
    "" -> derive_name_from_email(email)
    name -> name
  }

  User(
    id: id,
    email: email,
    password_hash: "",
    display_name: name,
    github_id: Some(github_id),
    created_at: now,
    updated_at: now,
  )
}
```

**Step 4: Update `from_db` function**

Update `from_db` (line 137-153) to include `github_id` parameter:

```gleam
pub fn from_db(
  id: String,
  email: String,
  password_hash: String,
  display_name: String,
  github_id: Option(String),
  created_at: Int,
  updated_at: Int,
) -> User {
  User(
    id: id,
    email: email,
    password_hash: password_hash,
    display_name: display_name,
    github_id: github_id,
    created_at: created_at,
    updated_at: updated_at,
  )
}
```

**Step 5: Update tests**

In `server/levee_auth/test/user_test.gleam`, add a test for `create_oauth`:

```gleam
pub fn create_oauth_user_test() {
  let oauth_user =
    user.create_oauth(
      email: "github@example.com",
      display_name: "GitHub User",
      github_id: "12345",
    )

  should.equal(oauth_user.email, "github@example.com")
  should.equal(oauth_user.display_name, "GitHub User")
  should.equal(oauth_user.github_id, option.Some("12345"))
  should.equal(oauth_user.password_hash, "")
  should.be_true(has_prefix(oauth_user.id, "usr_"))
}
```

Add the import at top of test file:

```gleam
import gleam/option
```

**Step 6: Run Gleam tests**

Run: `cd server/levee_auth && gleam test`
Expected: All tests pass

**Step 7: Format Gleam**

Run: `cd server/levee_auth && gleam format`

**Step 8: Commit**

```bash
git add server/levee_auth/src/user.gleam server/levee_auth/test/user_test.gleam
git commit -m "feat(auth): add github_id to Gleam User type and create_oauth function"
```

---

## Task 4: Update GleamBridge for new User tuple shape

**Files:**
- Modify: `server/lib/levee/auth/gleam_bridge.ex:262-271` (gleam_user_to_map)
- Modify: `server/lib/levee/auth/gleam_bridge.ex:339-342` (map_to_gleam_user)

**Step 1: Update `gleam_user_to_map`**

Replace the existing function (line 262-271) with:

```elixir
  defp gleam_user_to_map({:user, id, email, password_hash, display_name, github_id, created_at, updated_at}) do
    %{
      id: id,
      email: email,
      password_hash: password_hash,
      display_name: display_name,
      github_id: unwrap_option(github_id),
      created_at: created_at,
      updated_at: updated_at
    }
  end
```

**Step 2: Update `map_to_gleam_user`**

Replace the existing function (line 339-342) with:

```elixir
  defp map_to_gleam_user(user) do
    github_id = wrap_option(Map.get(user, :github_id))
    {:user, user.id, user.email, user.password_hash, user.display_name, github_id, user.created_at,
     user.updated_at}
  end
```

**Step 3: Add `wrap_option` helper**

After the existing `unwrap_option` helper (line 355-356), add:

```elixir
  defp wrap_option(nil), do: :none
  defp wrap_option(value), do: {:some, value}
```

**Step 4: Add `create_oauth_user` wrapper**

After the existing `create_user` function (around line 61-68), add:

```elixir
  @doc """
  Create a new user from OAuth (no password).
  """
  def create_oauth_user(email, display_name, github_id) do
    user = @gleam_user.create_oauth(email, display_name, github_id)
    gleam_user_to_map(user)
  end
```

**Step 5: Rebuild Gleam and verify Elixir compiles**

Run: `cd server && mix compile --force`
Expected: Compiles without errors

**Step 6: Run existing tests**

Run: `cd server && mix test`
Expected: All existing tests pass (the tuple shape change must be consistent)

**Step 7: Commit**

```bash
git add server/lib/levee/auth/gleam_bridge.ex
git commit -m "feat(auth): update GleamBridge for User with github_id field"
```

---

## Task 5: Add `find_user_by_github_id` to SessionStore

**Files:**
- Modify: `server/lib/levee/auth/session_store.ex:31-40` (after `find_user_by_email`)

**Step 1: Add the lookup function**

After `find_user_by_email` (line 32-40), add:

```elixir
  def find_user_by_github_id(github_id) do
    Agent.get(__MODULE__, fn state ->
      state.users
      |> Map.values()
      |> Enum.find_value(:error, fn user ->
        if user.github_id == github_id, do: {:ok, user}, else: nil
      end)
    end)
  end
```

**Step 2: Verify compilation**

Run: `cd server && mix compile`
Expected: Compiles without errors

**Step 3: Commit**

```bash
git add server/lib/levee/auth/session_store.ex
git commit -m "feat(auth): add find_user_by_github_id to SessionStore"
```

---

## Task 6: Add OAuth routes to router

**Files:**
- Modify: `server/lib/levee_web/router.ex:142-152` (before admin scope)

**Step 1: Add OAuth scope**

Before the admin UI scope (before line 142 `# Admin UI - SPA catch-all`), add:

```elixir
  # OAuth authentication routes
  scope "/auth", LeveeWeb do
    pipe_through :browser

    get "/:provider", OAuthController, :request
    get "/:provider/callback", OAuthController, :callback
  end

```

**Step 2: Verify compilation**

Run: `cd server && mix compile`
Expected: Will warn about missing OAuthController — that's fine, we create it next.

**Step 3: Commit**

```bash
git add server/lib/levee_web/router.ex
git commit -m "feat(auth): add OAuth routes to router"
```

---

## Task 7: Create OAuthController

**Files:**
- Create: `server/lib/levee_web/controllers/oauth_controller.ex`

**Step 1: Create the controller**

```elixir
defmodule LeveeWeb.OAuthController do
  use LeveeWeb, :controller

  plug Ueberauth

  alias Levee.Auth.GleamBridge
  alias Levee.Auth.SessionStore

  @doc """
  Handles the OAuth callback from the provider.

  On success: finds or creates user by GitHub ID, creates a session,
  and redirects to the frontend with the session token.
  """
  def callback(%{assigns: %{ueberauth_auth: auth}} = conn, _params) do
    github_id = to_string(auth.uid)
    email = auth.info.email || ""
    display_name = auth.info.name || auth.info.nickname || ""

    user =
      case SessionStore.find_user_by_github_id(github_id) do
        {:ok, existing_user} ->
          existing_user

        :error ->
          new_user = GleamBridge.create_oauth_user(email, display_name, github_id)
          SessionStore.store_user(new_user)
          new_user
      end

    session = GleamBridge.create_session(user.id, nil)
    SessionStore.store_session(session)

    redirect_url = get_redirect_url(conn, session.id)
    redirect(conn, external: redirect_url)
  end

  def callback(%{assigns: %{ueberauth_failure: failure}} = conn, _params) do
    messages =
      failure.errors
      |> Enum.map(& &1.message)
      |> Enum.join(", ")

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{error: %{code: "oauth_failed", message: messages}}))
  end

  defp get_redirect_url(conn, token) do
    # Use redirect_url query param if provided, otherwise default to /admin
    redirect_to = conn.params["redirect_url"] || "/admin"
    separator = if String.contains?(redirect_to, "?"), do: "&", else: "?"
    "#{redirect_to}#{separator}token=#{token}"
  end
end
```

**Step 2: Verify compilation**

Run: `cd server && mix compile`
Expected: Compiles without errors

**Step 3: Commit**

```bash
git add server/lib/levee_web/controllers/oauth_controller.ex
git commit -m "feat(auth): add OAuthController for GitHub OAuth callback"
```

---

## Task 8: Write controller tests

**Files:**
- Create: `server/test/levee_web/controllers/oauth_controller_test.exs`

**Step 1: Write the test file**

```elixir
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

    test "finds existing user on repeat login", %{conn: conn} do
      # First login — creates the user
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
      failure = %Ueberauth.Failure{
        provider: :github,
        strategy: Ueberauth.Strategy.Github,
        errors: [
          %Ueberauth.Failure.Error{
            message: "Access denied",
            message_key: "access_denied"
          }
        ]
      }

      conn =
        conn
        |> assign(:ueberauth_failure, failure)
        |> get("/auth/github/callback")

      assert %{"error" => error} = json_response(conn, 401)
      assert error["code"] == "oauth_failed"
      assert error["message"] =~ "Access denied"
    end
  end
end
```

**Step 2: Run the tests**

Run: `cd server && mix test test/levee_web/controllers/oauth_controller_test.exs`
Expected: All 4 tests pass

**Step 3: Run full test suite**

Run: `cd server && mix test`
Expected: All tests pass (including existing auth controller tests)

**Step 4: Commit**

```bash
git add server/test/levee_web/controllers/oauth_controller_test.exs
git commit -m "test(auth): add OAuthController tests for GitHub OAuth"
```

---

## Task 9: Update `user_to_json` in AuthController

**Files:**
- Modify: `server/lib/levee_web/controllers/auth_controller.ex:127-134`

**Step 1: Add github_id to JSON serialization**

Update the `user_to_json` function to include `github_id`:

```elixir
  defp user_to_json(user) do
    %{
      id: user.id,
      email: user.email,
      display_name: user.display_name,
      github_id: Map.get(user, :github_id),
      created_at: user.created_at
    }
  end
```

**Step 2: Run tests**

Run: `cd server && mix test`
Expected: All tests pass

**Step 3: Commit**

```bash
git add server/lib/levee_web/controllers/auth_controller.ex
git commit -m "feat(auth): include github_id in user JSON responses"
```

---

## Task 10: Final verification

**Step 1: Format all Elixir code**

Run: `cd server && mix format`

**Step 2: Format all Gleam code**

Run: `cd server/levee_auth && gleam format`

**Step 3: Run full Gleam test suite**

Run: `cd server/levee_auth && gleam test`
Expected: All tests pass

**Step 4: Run full Elixir test suite**

Run: `cd server && mix test`
Expected: All tests pass

**Step 5: Verify no compilation warnings**

Run: `cd server && mix compile --warnings-as-errors`
Expected: Clean compilation

**Step 6: Commit any formatting changes**

```bash
git add -A
git commit -m "chore: format code after GitHub OAuth implementation"
```
