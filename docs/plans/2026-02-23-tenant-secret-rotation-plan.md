# Tenant Secret Rotation Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace user-provided tenant IDs and secrets with server-generated values, support dual rotating secrets per tenant, and update the admin UI with per-slot regenerate buttons.

**Architecture:** Modify `TenantSecrets` GenServer to store `%{tenant_id => %{name, secret1, secret2}}` instead of `%{tenant_id => secret}`. Update `JWT.verify/2` to try both secrets. Add `unique_names_generator` dependency for human-readable tenant IDs. Update controller, tests, and Lustre admin SPA.

**Tech Stack:** Elixir (Phoenix), Gleam (Lustre SPA), unique_names_generator (Hex)

---

### Task 1: Add unique_names_generator dependency

**Files:**
- Modify: `server/mix.exs:40-59` (deps function)

**Step 1: Add the dependency**

In `server/mix.exs`, add to the `deps` list:

```elixir
# Tenant ID generation
{:unique_names_generator, "~> 0.2.0"},
```

**Step 2: Install**

Run: `cd server && mix deps.get`
Expected: resolves and fetches `unique_names_generator`

**Step 3: Verify**

Run: `cd server && mix compile`
Expected: compiles successfully

**Step 4: Commit**

```bash
git add server/mix.exs server/mix.lock
git commit -m "feat(deps): add unique_names_generator for tenant IDs"
```

---

### Task 2: Update TenantSecrets GenServer — data model and API

**Files:**
- Modify: `server/lib/levee/auth/tenant_secrets.ex`
- Modify: `server/test/levee/auth/tenant_secrets_test.exs`

**Step 1: Write the failing tests**

Replace `server/test/levee/auth/tenant_secrets_test.exs` entirely:

```elixir
defmodule Levee.Auth.TenantSecretsTest do
  use ExUnit.Case, async: false

  alias Levee.Auth.TenantSecrets

  setup do
    # Clean up all test tenants
    for id <- TenantSecrets.list_tenants() do
      TenantSecrets.unregister_tenant(id)
    end

    on_exit(fn ->
      for id <- TenantSecrets.list_tenants() do
        TenantSecrets.unregister_tenant(id)
      end
    end)

    :ok
  end

  describe "create_tenant/1" do
    test "creates a tenant with server-generated ID and secrets" do
      {:ok, tenant} = TenantSecrets.create_tenant("My App")

      assert is_binary(tenant.id)
      assert tenant.name == "My App"
      assert is_binary(tenant.secret1)
      assert is_binary(tenant.secret2)
      assert String.length(tenant.secret1) == 64
      assert String.length(tenant.secret2) == 64
      assert tenant.secret1 != tenant.secret2
      assert TenantSecrets.tenant_exists?(tenant.id)
    end

    test "generates hyphenated adjective-color-animal ID" do
      {:ok, tenant} = TenantSecrets.create_tenant("Test")

      parts = String.split(tenant.id, "-")
      assert length(parts) == 3
    end

    test "generates unique IDs for different tenants" do
      {:ok, t1} = TenantSecrets.create_tenant("App 1")
      {:ok, t2} = TenantSecrets.create_tenant("App 2")

      assert t1.id != t2.id
    end
  end

  describe "get_tenant/1" do
    test "returns tenant info without secrets" do
      {:ok, created} = TenantSecrets.create_tenant("My App")

      assert {:ok, tenant} = TenantSecrets.get_tenant(created.id)
      assert tenant.id == created.id
      assert tenant.name == "My App"
      refute Map.has_key?(tenant, :secret1)
      refute Map.has_key?(tenant, :secret2)
    end

    test "returns error for non-existent tenant" do
      assert {:error, :tenant_not_found} = TenantSecrets.get_tenant("nonexistent")
    end
  end

  describe "get_secrets/1" do
    test "returns both secrets for a tenant" do
      {:ok, created} = TenantSecrets.create_tenant("My App")

      assert {:ok, %{secret1: s1, secret2: s2}} = TenantSecrets.get_secrets(created.id)
      assert s1 == created.secret1
      assert s2 == created.secret2
    end

    test "returns error for non-existent tenant" do
      assert {:error, :tenant_not_found} = TenantSecrets.get_secrets("nonexistent")
    end
  end

  describe "regenerate_secret/2" do
    test "regenerates secret1" do
      {:ok, created} = TenantSecrets.create_tenant("My App")
      old_secret1 = created.secret1

      {:ok, new_secret} = TenantSecrets.regenerate_secret(created.id, 1)

      assert new_secret != old_secret1
      assert String.length(new_secret) == 64

      {:ok, secrets} = TenantSecrets.get_secrets(created.id)
      assert secrets.secret1 == new_secret
      assert secrets.secret2 == created.secret2
    end

    test "regenerates secret2" do
      {:ok, created} = TenantSecrets.create_tenant("My App")
      old_secret2 = created.secret2

      {:ok, new_secret} = TenantSecrets.regenerate_secret(created.id, 2)

      assert new_secret != old_secret2

      {:ok, secrets} = TenantSecrets.get_secrets(created.id)
      assert secrets.secret1 == created.secret1
      assert secrets.secret2 == new_secret
    end

    test "returns error for invalid slot" do
      {:ok, created} = TenantSecrets.create_tenant("My App")

      assert {:error, :invalid_slot} = TenantSecrets.regenerate_secret(created.id, 3)
    end

    test "returns error for non-existent tenant" do
      assert {:error, :tenant_not_found} = TenantSecrets.regenerate_secret("nonexistent", 1)
    end
  end

  describe "unregister_tenant/1" do
    test "removes a tenant" do
      {:ok, tenant} = TenantSecrets.create_tenant("My App")
      :ok = TenantSecrets.unregister_tenant(tenant.id)

      refute TenantSecrets.tenant_exists?(tenant.id)
    end

    test "succeeds for non-existent tenant" do
      :ok = TenantSecrets.unregister_tenant("non-existent")
    end
  end

  describe "list_tenants/0" do
    test "returns list of tenant IDs" do
      {:ok, t1} = TenantSecrets.create_tenant("App 1")
      {:ok, t2} = TenantSecrets.create_tenant("App 2")

      tenants = TenantSecrets.list_tenants()
      assert t1.id in tenants
      assert t2.id in tenants
    end
  end

  describe "list_tenants_with_names/0" do
    test "returns list of {id, name} maps" do
      {:ok, t1} = TenantSecrets.create_tenant("App 1")
      {:ok, t2} = TenantSecrets.create_tenant("App 2")

      tenants = TenantSecrets.list_tenants_with_names()
      ids = Enum.map(tenants, & &1.id)
      assert t1.id in ids
      assert t2.id in ids

      app1 = Enum.find(tenants, &(&1.id == t1.id))
      assert app1.name == "App 1"
    end
  end

  describe "generate_secret/0" do
    test "returns 64-character hex string" do
      secret = TenantSecrets.generate_secret()

      assert String.length(secret) == 64
      assert Regex.match?(~r/^[0-9a-f]{64}$/, secret)
    end

    test "generates unique values" do
      s1 = TenantSecrets.generate_secret()
      s2 = TenantSecrets.generate_secret()

      assert s1 != s2
    end
  end

  describe "backward compatibility" do
    test "register_tenant/2 still works for existing callers" do
      :ok = TenantSecrets.register_tenant("legacy-id", "legacy-secret")

      assert TenantSecrets.tenant_exists?("legacy-id")
      assert {:ok, %{secret1: "legacy-secret", secret2: _}} = TenantSecrets.get_secrets("legacy-id")
    end

    test "get_secret/1 returns secret1 for backward compat" do
      :ok = TenantSecrets.register_tenant("legacy-id", "legacy-secret")

      assert {:ok, "legacy-secret"} = TenantSecrets.get_secret("legacy-id")
    end

    test "register_dev_tenant works" do
      :ok = TenantSecrets.register_dev_tenant("dev-test")

      assert TenantSecrets.tenant_exists?("dev-test")
    end
  end
end
```

**Step 2: Run tests to verify they fail**

Run: `cd server && mix test test/levee/auth/tenant_secrets_test.exs`
Expected: Many failures (new functions don't exist yet)

**Step 3: Implement the updated TenantSecrets**

Replace `server/lib/levee/auth/tenant_secrets.ex` with:

```elixir
defmodule Levee.Auth.TenantSecrets do
  @moduledoc """
  Manages tenant registration and secrets for JWT signing and verification.

  Each tenant has a server-generated ID (human-readable), a user-provided name,
  and two rotating secrets. Both secrets are valid for JWT verification (try-both),
  and secret1 is used for signing new tokens.
  """

  use GenServer

  require Logger

  @default_dev_secret "levee-dev-secret-change-in-production"

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Creates a new tenant with a server-generated ID and two secrets.
  Returns `{:ok, %{id, name, secret1, secret2}}`.
  """
  @spec create_tenant(String.t()) :: {:ok, map()}
  def create_tenant(name) do
    GenServer.call(__MODULE__, {:create_tenant, name})
  end

  @doc """
  Returns tenant info (id, name) without secrets.
  """
  @spec get_tenant(String.t()) :: {:ok, map()} | {:error, :tenant_not_found}
  def get_tenant(tenant_id) do
    GenServer.call(__MODULE__, {:get_tenant, tenant_id})
  end

  @doc """
  Returns both secrets for a tenant.
  """
  @spec get_secrets(String.t()) :: {:ok, %{secret1: String.t(), secret2: String.t()}} | {:error, :tenant_not_found}
  def get_secrets(tenant_id) do
    GenServer.call(__MODULE__, {:get_secrets, tenant_id})
  end

  @doc """
  Regenerates one of a tenant's secrets (slot 1 or 2).
  Returns `{:ok, new_secret}`.
  """
  @spec regenerate_secret(String.t(), 1 | 2) :: {:ok, String.t()} | {:error, :tenant_not_found | :invalid_slot}
  def regenerate_secret(tenant_id, slot) when slot in [1, 2] do
    GenServer.call(__MODULE__, {:regenerate_secret, tenant_id, slot})
  end

  def regenerate_secret(_tenant_id, _slot) do
    {:error, :invalid_slot}
  end

  @doc """
  Backward-compatible: registers a tenant with an explicit ID and secret.
  Stores the secret as secret1, generates secret2.
  """
  @spec register_tenant(String.t(), String.t()) :: :ok
  def register_tenant(tenant_id, secret) do
    GenServer.call(__MODULE__, {:register_tenant, tenant_id, secret})
  end

  @spec unregister_tenant(String.t()) :: :ok
  def unregister_tenant(tenant_id) do
    GenServer.call(__MODULE__, {:unregister_tenant, tenant_id})
  end

  @doc """
  Backward-compatible: returns secret1 for the tenant.
  """
  @spec get_secret(String.t()) :: {:ok, String.t()} | {:error, :tenant_not_found}
  def get_secret(tenant_id) do
    GenServer.call(__MODULE__, {:get_secret, tenant_id})
  end

  @spec tenant_exists?(String.t()) :: boolean()
  def tenant_exists?(tenant_id) do
    GenServer.call(__MODULE__, {:tenant_exists?, tenant_id})
  end

  @spec list_tenants() :: [String.t()]
  def list_tenants do
    GenServer.call(__MODULE__, :list_tenants)
  end

  @doc """
  Lists tenants with their names (no secrets).
  """
  @spec list_tenants_with_names() :: [%{id: String.t(), name: String.t()}]
  def list_tenants_with_names do
    GenServer.call(__MODULE__, :list_tenants_with_names)
  end

  @spec register_dev_tenant(String.t()) :: :ok
  def register_dev_tenant(tenant_id \\ "dev-tenant") do
    register_tenant(tenant_id, @default_dev_secret)
  end

  @spec default_dev_secret() :: String.t()
  def default_dev_secret, do: @default_dev_secret

  @doc """
  Generates a cryptographically secure 32-byte hex secret.
  """
  @spec generate_secret() :: String.t()
  def generate_secret do
    :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
  end

  @doc """
  Generates a human-readable tenant ID (adjective-color-animal).
  """
  @spec generate_tenant_id(map()) :: String.t()
  def generate_tenant_id(existing_tenants, retries \\ 5)

  def generate_tenant_id(_existing_tenants, 0) do
    # Fallback: append random suffix
    base = UniqueNamesGenerator.generate([:adjectives, :colors, :animals], %{separator: "-"})
    suffix = :crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower)
    base <> "-" <> suffix
  end

  def generate_tenant_id(existing_tenants, retries) do
    id = UniqueNamesGenerator.generate([:adjectives, :colors, :animals], %{separator: "-"})

    if Map.has_key?(existing_tenants, id) do
      generate_tenant_id(existing_tenants, retries - 1)
    else
      id
    end
  end

  # Server callbacks

  @impl true
  def init(opts) do
    initial_tenants = Keyword.get(opts, :tenants, %{})

    state = %{tenants: initial_tenants}

    state =
      case {System.get_env("LEVEE_TENANT_ID"), System.get_env("LEVEE_TENANT_KEY")} do
        {tenant_id, tenant_key} when is_binary(tenant_id) and is_binary(tenant_key) ->
          Logger.info("Registering tenant from environment: #{tenant_id}")
          data = %{name: tenant_id, secret1: tenant_key, secret2: generate_secret()}
          put_in(state.tenants[tenant_id], data)

        _ ->
          state
      end

    {:ok, state}
  end

  @impl true
  def handle_call({:create_tenant, name}, _from, state) do
    id = generate_tenant_id(state.tenants)
    secret1 = generate_secret()
    secret2 = generate_secret()
    data = %{name: name, secret1: secret1, secret2: secret2}
    new_state = put_in(state.tenants[id], data)

    result = %{id: id, name: name, secret1: secret1, secret2: secret2}
    Logger.info("Created tenant: #{id} (#{name})")
    {:reply, {:ok, result}, new_state}
  end

  def handle_call({:get_tenant, tenant_id}, _from, state) do
    case Map.get(state.tenants, tenant_id) do
      nil -> {:reply, {:error, :tenant_not_found}, state}
      data -> {:reply, {:ok, %{id: tenant_id, name: data.name}}, state}
    end
  end

  def handle_call({:get_secrets, tenant_id}, _from, state) do
    case Map.get(state.tenants, tenant_id) do
      nil -> {:reply, {:error, :tenant_not_found}, state}
      data -> {:reply, {:ok, %{secret1: data.secret1, secret2: data.secret2}}, state}
    end
  end

  def handle_call({:regenerate_secret, tenant_id, slot}, _from, state) do
    case Map.get(state.tenants, tenant_id) do
      nil ->
        {:reply, {:error, :tenant_not_found}, state}

      data ->
        new_secret = generate_secret()
        key = if slot == 1, do: :secret1, else: :secret2
        new_data = Map.put(data, key, new_secret)
        new_state = put_in(state.tenants[tenant_id], new_data)
        Logger.info("Regenerated secret#{slot} for tenant: #{tenant_id}")
        {:reply, {:ok, new_secret}, new_state}
    end
  end

  def handle_call({:register_tenant, tenant_id, secret}, _from, state) do
    Logger.info("Registering tenant: #{tenant_id}")
    data = %{name: tenant_id, secret1: secret, secret2: generate_secret()}
    new_state = put_in(state.tenants[tenant_id], data)
    {:reply, :ok, new_state}
  end

  def handle_call({:unregister_tenant, tenant_id}, _from, state) do
    Logger.info("Unregistering tenant: #{tenant_id}")
    new_state = update_in(state.tenants, &Map.delete(&1, tenant_id))
    {:reply, :ok, new_state}
  end

  def handle_call({:get_secret, tenant_id}, _from, state) do
    case Map.get(state.tenants, tenant_id) do
      nil -> {:reply, {:error, :tenant_not_found}, state}
      data -> {:reply, {:ok, data.secret1}, state}
    end
  end

  def handle_call({:tenant_exists?, tenant_id}, _from, state) do
    {:reply, Map.has_key?(state.tenants, tenant_id), state}
  end

  def handle_call(:list_tenants, _from, state) do
    {:reply, Map.keys(state.tenants), state}
  end

  def handle_call(:list_tenants_with_names, _from, state) do
    list =
      state.tenants
      |> Enum.map(fn {id, data} -> %{id: id, name: data.name} end)

    {:reply, list, state}
  end
end
```

**Step 4: Run tests**

Run: `cd server && mix test test/levee/auth/tenant_secrets_test.exs`
Expected: All pass

**Step 5: Commit**

```bash
git add server/lib/levee/auth/tenant_secrets.ex server/test/levee/auth/tenant_secrets_test.exs
git commit -m "feat(auth): server-generated tenant IDs and dual rotating secrets

TenantSecrets now generates human-readable IDs via unique_names_generator
and two 32-byte hex secrets per tenant. Backward-compatible register_tenant/2
and get_secret/1 are preserved for existing callers."
```

---

### Task 3: Update JWT verification to try both secrets

**Files:**
- Modify: `server/lib/levee/auth/jwt.ex:98-118` (verify function)
- Modify: `server/test/levee/auth/jwt_test.exs`

**Step 1: Write the failing tests**

Add these tests to `server/test/levee/auth/jwt_test.exs` in a new describe block before the closing `end`:

```elixir
describe "verify/2 with dual secrets" do
  test "verifies token signed with secret1" do
    {:ok, tenant} = TenantSecrets.create_tenant("Dual Test")
    on_exit(fn -> TenantSecrets.unregister_tenant(tenant.id) end)

    # Sign manually with secret1
    claims = %{
      documentId: @document_id,
      scopes: ["doc:read"],
      tenantId: tenant.id,
      user: %{id: @user_id}
    }

    {:ok, token} = JWT.sign(claims, tenant.id)
    assert {:ok, _claims} = JWT.verify(token, tenant.id)
  end

  test "verifies token signed with secret2" do
    {:ok, tenant} = TenantSecrets.create_tenant("Dual Test 2")
    on_exit(fn -> TenantSecrets.unregister_tenant(tenant.id) end)

    # Sign a token directly with secret2 using JOSE
    jwk = JOSE.JWK.from_oct(tenant.secret2)
    jws = %{"alg" => "HS256"}
    now = System.system_time(:second)

    payload =
      Jason.encode!(%{
        documentId: @document_id,
        scopes: ["doc:read"],
        tenantId: tenant.id,
        user: %{id: @user_id},
        iat: now,
        exp: now + 3600,
        ver: "1.0"
      })

    {_, token} = JOSE.JWS.compact(JOSE.JWT.sign(jwk, jws, payload))

    assert {:ok, claims} = JWT.verify(token, tenant.id)
    assert claims.tenantId == tenant.id
  end

  test "rejects token signed with neither secret" do
    {:ok, tenant} = TenantSecrets.create_tenant("Dual Test 3")
    on_exit(fn -> TenantSecrets.unregister_tenant(tenant.id) end)

    # Sign with a random secret
    jwk = JOSE.JWK.from_oct("totally-wrong-secret-not-in-tenant")
    jws = %{"alg" => "HS256"}
    now = System.system_time(:second)

    payload =
      Jason.encode!(%{
        documentId: @document_id,
        scopes: ["doc:read"],
        tenantId: tenant.id,
        user: %{id: @user_id},
        iat: now,
        exp: now + 3600,
        ver: "1.0"
      })

    {_, token} = JOSE.JWS.compact(JOSE.JWT.sign(jwk, jws, payload))

    assert {:error, :invalid_signature} = JWT.verify(token, tenant.id)
  end

  test "after regenerating secret1, old secret1 tokens fail but secret2 tokens work" do
    {:ok, tenant} = TenantSecrets.create_tenant("Rotation Test")
    on_exit(fn -> TenantSecrets.unregister_tenant(tenant.id) end)

    # Sign a token with secret1 (the default for JWT.sign)
    claims = %{
      documentId: @document_id,
      scopes: ["doc:read"],
      tenantId: tenant.id,
      user: %{id: @user_id}
    }

    {:ok, old_s1_token} = JWT.sign(claims, tenant.id)

    # Sign a token with secret2 manually
    jwk2 = JOSE.JWK.from_oct(tenant.secret2)
    jws = %{"alg" => "HS256"}
    now = System.system_time(:second)

    payload =
      Jason.encode!(%{
        documentId: @document_id,
        scopes: ["doc:read"],
        tenantId: tenant.id,
        user: %{id: @user_id},
        iat: now,
        exp: now + 3600,
        ver: "1.0"
      })

    {_, s2_token} = JOSE.JWS.compact(JOSE.JWT.sign(jwk2, jws, payload))

    # Both should verify before rotation
    assert {:ok, _} = JWT.verify(old_s1_token, tenant.id)
    assert {:ok, _} = JWT.verify(s2_token, tenant.id)

    # Regenerate secret1
    {:ok, _new_secret} = TenantSecrets.regenerate_secret(tenant.id, 1)

    # Old secret1 token should now fail
    assert {:error, :invalid_signature} = JWT.verify(old_s1_token, tenant.id)

    # Secret2 token should still work
    assert {:ok, _} = JWT.verify(s2_token, tenant.id)
  end
end
```

**Step 2: Run tests to verify failures**

Run: `cd server && mix test test/levee/auth/jwt_test.exs`
Expected: New dual-secret tests fail (verify only tries secret1 currently)

**Step 3: Update JWT.verify/2 to try both secrets**

In `server/lib/levee/auth/jwt.ex`, replace the `verify/2` function (lines 98-118):

```elixir
@spec verify(String.t(), String.t()) :: {:ok, token_claims()} | {:error, term()}
def verify(token, tenant_id) do
  case TenantSecrets.get_secrets(tenant_id) do
    {:ok, %{secret1: secret1, secret2: secret2}} ->
      case verify_with_secret(token, secret1) do
        {:ok, claims} ->
          {:ok, claims}

        {:error, :invalid_signature} ->
          verify_with_secret(token, secret2)

        {:error, reason} ->
          {:error, reason}
      end

    {:error, :tenant_not_found} ->
      {:error, {:tenant_secret_not_found, :tenant_not_found}}
  end
end

defp verify_with_secret(token, secret) do
  jwk = JOSE.JWK.from_oct(secret)

  case JOSE.JWT.verify_strict(jwk, ["HS256"], token) do
    {true, %JOSE.JWT{fields: fields}, _jws} ->
      {:ok, atomize_claims(fields)}

    {false, _jwt, _jws} ->
      {:error, :invalid_signature}

    {:error, reason} ->
      {:error, {:jwt_decode_error, reason}}
  end
end
```

Also update `sign/2` to use `get_secrets` (lines 64-85):

```elixir
@spec sign(token_claims(), String.t()) :: {:ok, String.t()} | {:error, term()}
def sign(claims, tenant_id) do
  case TenantSecrets.get_secrets(tenant_id) do
    {:ok, %{secret1: secret}} ->
      jwk = JOSE.JWK.from_oct(secret)
      jws = %{"alg" => "HS256"}

      claims_with_defaults =
        claims
        |> Map.put_new(:iat, System.system_time(:second))
        |> Map.put_new(:exp, System.system_time(:second) + @default_expiration_seconds)
        |> Map.put_new(:ver, @token_version)

      payload = Jason.encode!(claims_with_defaults)

      {_, token} = JOSE.JWS.compact(JOSE.JWT.sign(jwk, jws, payload))
      {:ok, token}

    {:error, :tenant_not_found} ->
      {:error, {:tenant_secret_not_found, :tenant_not_found}}
  end
end
```

**Step 4: Run all JWT tests**

Run: `cd server && mix test test/levee/auth/jwt_test.exs`
Expected: All pass (existing + new dual-secret tests)

**Step 5: Run full test suite to check backward compat**

Run: `cd server && mix test`
Expected: All pass — existing callers of `register_tenant/2` and `get_secret/1` still work

**Step 6: Commit**

```bash
git add server/lib/levee/auth/jwt.ex server/test/levee/auth/jwt_test.exs
git commit -m "feat(auth): JWT verification tries both tenant secrets

sign/2 always uses secret1. verify/2 tries secret1 first, then
falls back to secret2. Enables zero-downtime secret rotation."
```

---

### Task 4: Update TenantAdminController and routes

**Files:**
- Modify: `server/lib/levee_web/controllers/tenant_admin_controller.ex`
- Modify: `server/lib/levee_web/router.ex:132-156`
- Modify: `server/test/levee_web/controllers/tenant_admin_controller_test.exs`

**Step 1: Write the failing tests**

Replace `server/test/levee_web/controllers/tenant_admin_controller_test.exs`:

```elixir
defmodule LeveeWeb.TenantAdminControllerTest do
  use LeveeWeb.ConnCase

  alias Levee.Auth.GleamBridge
  alias Levee.Auth.SessionStore
  alias Levee.Auth.TenantSecrets

  setup do
    SessionStore.clear()

    {:ok, admin_user} =
      GleamBridge.create_user("admin@example.com", "admin_password_123", "Admin User")

    admin_user = %{admin_user | is_admin: true}
    SessionStore.store_user(admin_user)

    admin_session = GleamBridge.create_session(admin_user.id, nil)
    SessionStore.store_session(admin_session)

    {:ok, regular_user} =
      GleamBridge.create_user("user@example.com", "user_password_123", "Regular User")

    SessionStore.store_user(regular_user)

    regular_session = GleamBridge.create_session(regular_user.id, nil)
    SessionStore.store_session(regular_session)

    on_exit(fn ->
      for tenant_id <- TenantSecrets.list_tenants() do
        TenantSecrets.unregister_tenant(tenant_id)
      end
    end)

    {:ok,
     admin_user: admin_user,
     admin_session: admin_session,
     regular_user: regular_user,
     regular_session: regular_session}
  end

  defp auth_header(conn, session) do
    put_req_header(conn, "authorization", "Bearer #{session.id}")
  end

  describe "GET /api/tenants" do
    test "returns empty list when no tenants exist", %{conn: conn, admin_session: session} do
      conn =
        conn
        |> auth_header(session)
        |> get("/api/tenants")

      assert %{"tenants" => []} = json_response(conn, 200)
    end

    test "returns list of tenants with names", %{conn: conn, admin_session: session} do
      {:ok, t1} = TenantSecrets.create_tenant("App One")
      {:ok, t2} = TenantSecrets.create_tenant("App Two")

      conn =
        conn
        |> auth_header(session)
        |> get("/api/tenants")

      assert %{"tenants" => tenants} = json_response(conn, 200)
      ids = Enum.map(tenants, & &1["id"])
      assert t1.id in ids
      assert t2.id in ids

      app1 = Enum.find(tenants, &(&1["id"] == t1.id))
      assert app1["name"] == "App One"
      refute Map.has_key?(app1, "secret1")
      refute Map.has_key?(app1, "secret2")
    end

    test "returns 401 without authorization", %{conn: conn} do
      conn = get(conn, "/api/tenants")
      assert %{"error" => error} = json_response(conn, 401)
      assert error["code"] == "unauthorized"
    end

    test "returns 403 for non-admin user", %{conn: conn, regular_session: session} do
      conn =
        conn
        |> auth_header(session)
        |> get("/api/tenants")

      assert %{"error" => error} = json_response(conn, 403)
      assert error["code"] == "forbidden"
    end
  end

  describe "POST /api/tenants" do
    test "creates tenant with server-generated ID and secrets", %{
      conn: conn,
      admin_session: session
    } do
      conn =
        conn
        |> auth_header(session)
        |> put_req_header("content-type", "application/json")
        |> post("/api/tenants", %{name: "My New App"})

      assert %{"tenant" => tenant} = json_response(conn, 201)
      assert is_binary(tenant["id"])
      assert tenant["name"] == "My New App"
      assert is_binary(tenant["secret1"])
      assert is_binary(tenant["secret2"])
      assert String.length(tenant["secret1"]) == 64
      assert String.length(tenant["secret2"]) == 64
      assert TenantSecrets.tenant_exists?(tenant["id"])
    end

    test "returns 422 when name is missing", %{conn: conn, admin_session: session} do
      conn =
        conn
        |> auth_header(session)
        |> put_req_header("content-type", "application/json")
        |> post("/api/tenants", %{})

      assert %{"error" => error} = json_response(conn, 422)
      assert error["code"] == "missing_fields"
    end

    test "returns 401 without authorization", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/tenants", %{name: "Test"})

      assert %{"error" => error} = json_response(conn, 401)
      assert error["code"] == "unauthorized"
    end

    test "returns 403 for non-admin user", %{conn: conn, regular_session: session} do
      conn =
        conn
        |> auth_header(session)
        |> put_req_header("content-type", "application/json")
        |> post("/api/tenants", %{name: "Test"})

      assert %{"error" => error} = json_response(conn, 403)
      assert error["code"] == "forbidden"
    end
  end

  describe "GET /api/tenants/:id" do
    test "returns tenant info without secrets", %{conn: conn, admin_session: session} do
      {:ok, created} = TenantSecrets.create_tenant("My App")

      conn =
        conn
        |> auth_header(session)
        |> get("/api/tenants/#{created.id}")

      assert %{"tenant" => tenant} = json_response(conn, 200)
      assert tenant["id"] == created.id
      assert tenant["name"] == "My App"
      refute Map.has_key?(tenant, "secret1")
      refute Map.has_key?(tenant, "secret2")
    end

    test "returns 404 when tenant does not exist", %{conn: conn, admin_session: session} do
      conn =
        conn
        |> auth_header(session)
        |> get("/api/tenants/nonexistent")

      assert %{"error" => error} = json_response(conn, 404)
      assert error["code"] == "not_found"
    end
  end

  describe "POST /api/tenants/:id/secrets/:slot" do
    test "regenerates secret1", %{conn: conn, admin_session: session} do
      {:ok, created} = TenantSecrets.create_tenant("Regen Test")

      conn =
        conn
        |> auth_header(session)
        |> post("/api/tenants/#{created.id}/secrets/1")

      assert %{"secret" => new_secret} = json_response(conn, 200)
      assert is_binary(new_secret)
      assert String.length(new_secret) == 64
      assert new_secret != created.secret1

      {:ok, secrets} = TenantSecrets.get_secrets(created.id)
      assert secrets.secret1 == new_secret
      assert secrets.secret2 == created.secret2
    end

    test "regenerates secret2", %{conn: conn, admin_session: session} do
      {:ok, created} = TenantSecrets.create_tenant("Regen Test 2")

      conn =
        conn
        |> auth_header(session)
        |> post("/api/tenants/#{created.id}/secrets/2")

      assert %{"secret" => new_secret} = json_response(conn, 200)
      assert new_secret != created.secret2
    end

    test "returns 400 for invalid slot", %{conn: conn, admin_session: session} do
      {:ok, created} = TenantSecrets.create_tenant("Regen Test 3")

      conn =
        conn
        |> auth_header(session)
        |> post("/api/tenants/#{created.id}/secrets/3")

      assert %{"error" => error} = json_response(conn, 400)
      assert error["code"] == "invalid_slot"
    end

    test "returns 404 for non-existent tenant", %{conn: conn, admin_session: session} do
      conn =
        conn
        |> auth_header(session)
        |> post("/api/tenants/nonexistent/secrets/1")

      assert %{"error" => error} = json_response(conn, 404)
      assert error["code"] == "not_found"
    end

    test "returns 401 without authorization", %{conn: conn} do
      conn = post(conn, "/api/tenants/some-id/secrets/1")
      assert %{"error" => error} = json_response(conn, 401)
      assert error["code"] == "unauthorized"
    end

    test "returns 403 for non-admin user", %{conn: conn, regular_session: session} do
      conn =
        conn
        |> auth_header(session)
        |> post("/api/tenants/some-id/secrets/1")

      assert %{"error" => error} = json_response(conn, 403)
      assert error["code"] == "forbidden"
    end
  end

  describe "DELETE /api/tenants/:id" do
    test "deletes an existing tenant", %{conn: conn, admin_session: session} do
      {:ok, tenant} = TenantSecrets.create_tenant("Delete Me")
      assert TenantSecrets.tenant_exists?(tenant.id)

      conn =
        conn
        |> auth_header(session)
        |> delete("/api/tenants/#{tenant.id}")

      assert %{"message" => _} = json_response(conn, 200)
      refute TenantSecrets.tenant_exists?(tenant.id)
    end

    test "returns 404 when tenant does not exist", %{conn: conn, admin_session: session} do
      conn =
        conn
        |> auth_header(session)
        |> delete("/api/tenants/nonexistent")

      assert %{"error" => error} = json_response(conn, 404)
      assert error["code"] == "not_found"
    end
  end
end
```

**Step 2: Run tests to verify failures**

Run: `cd server && mix test test/levee_web/controllers/tenant_admin_controller_test.exs`
Expected: Failures for new create shape, regenerate routes, etc.

**Step 3: Update the controller**

Replace `server/lib/levee_web/controllers/tenant_admin_controller.ex`:

```elixir
defmodule LeveeWeb.TenantAdminController do
  use LeveeWeb, :controller

  alias Levee.Auth.TenantSecrets

  def index(conn, _params) do
    tenants = TenantSecrets.list_tenants_with_names()
    json(conn, %{tenants: tenants})
  end

  def create(conn, %{"name" => name}) do
    {:ok, tenant} = TenantSecrets.create_tenant(name)

    conn
    |> put_status(:created)
    |> json(%{tenant: tenant})
  end

  def create(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "missing_fields", message: "Required: name"}})
  end

  def show(conn, %{"id" => tenant_id}) do
    case TenantSecrets.get_tenant(tenant_id) do
      {:ok, tenant} ->
        json(conn, %{tenant: tenant})

      {:error, :tenant_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "not_found", message: "Tenant not found"}})
    end
  end

  def regenerate_secret(conn, %{"id" => tenant_id, "slot" => slot_str}) do
    case Integer.parse(slot_str) do
      {slot, ""} when slot in [1, 2] ->
        case TenantSecrets.regenerate_secret(tenant_id, slot) do
          {:ok, new_secret} ->
            json(conn, %{secret: new_secret})

          {:error, :tenant_not_found} ->
            conn
            |> put_status(:not_found)
            |> json(%{error: %{code: "not_found", message: "Tenant not found"}})
        end

      _ ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: %{code: "invalid_slot", message: "Slot must be 1 or 2"}})
    end
  end

  def delete(conn, %{"id" => tenant_id}) do
    if TenantSecrets.tenant_exists?(tenant_id) do
      :ok = TenantSecrets.unregister_tenant(tenant_id)
      json(conn, %{message: "Tenant unregistered"})
    else
      conn
      |> put_status(:not_found)
      |> json(%{error: %{code: "not_found", message: "Tenant not found"}})
    end
  end
end
```

**Step 4: Update routes**

In `server/lib/levee_web/router.ex`, replace the admin routes (lines 132-156):

```elixir
  scope "/api/admin", LeveeWeb do
    pipe_through :admin_auth

    get "/tenants", TenantAdminController, :index
    post "/tenants", TenantAdminController, :create
    get "/tenants/:id", TenantAdminController, :show
    delete "/tenants/:id", TenantAdminController, :delete
    post "/tenants/:id/secrets/:slot", TenantAdminController, :regenerate_secret
  end

  scope "/api/tenants", LeveeWeb do
    pipe_through :admin_session

    get "/", TenantAdminController, :index
    post "/", TenantAdminController, :create
    get "/:id", TenantAdminController, :show
    delete "/:id", TenantAdminController, :delete
    post "/:id/secrets/:slot", TenantAdminController, :regenerate_secret
  end
```

**Step 5: Run controller tests**

Run: `cd server && mix test test/levee_web/controllers/tenant_admin_controller_test.exs`
Expected: All pass

**Step 6: Run full test suite**

Run: `cd server && mix test`
Expected: All pass

**Step 7: Commit**

```bash
git add server/lib/levee_web/controllers/tenant_admin_controller.ex server/lib/levee_web/router.ex server/test/levee_web/controllers/tenant_admin_controller_test.exs
git commit -m "feat(admin): server-generated tenants with per-slot secret regeneration

POST /api/tenants now accepts {name} and returns {id, name, secret1, secret2}.
PUT replaced by POST /tenants/:id/secrets/:slot for per-slot regeneration.
List and show endpoints now return name alongside ID, never secrets."
```

---

### Task 5: Update Admin UI — API client and types

**Files:**
- Modify: `server/levee_admin/src/levee_admin/api.gleam`

**Step 1: Update types and decoders**

Replace the Tenant API section (lines 278-403) of `server/levee_admin/src/levee_admin/api.gleam`:

```gleam
// ─────────────────────────────────────────────────────────────────────────────
// Tenant API
// ─────────────────────────────────────────────────────────────────────────────

pub type Tenant {
  Tenant(id: String, name: String)
}

pub type TenantWithSecrets {
  TenantWithSecrets(id: String, name: String, secret1: String, secret2: String)
}

pub type TenantList {
  TenantList(tenants: List(Tenant))
}

pub type RegenerateResponse {
  RegenerateResponse(secret: String)
}

pub type DeleteResponse {
  DeleteResponse(message: String)
}

fn tenant_decoder() -> Decoder(Tenant) {
  use id <- decode.field("id", decode.string)
  use name <- decode.field("name", decode.string)
  decode.success(Tenant(id:, name:))
}

fn tenant_with_secrets_decoder() -> Decoder(TenantWithSecrets) {
  use id <- decode.field("id", decode.string)
  use name <- decode.field("name", decode.string)
  use secret1 <- decode.field("secret1", decode.string)
  use secret2 <- decode.field("secret2", decode.string)
  decode.success(TenantWithSecrets(id:, name:, secret1:, secret2:))
}

fn tenant_list_decoder() -> Decoder(TenantList) {
  use tenants <- decode.field("tenants", decode.list(tenant_decoder()))
  decode.success(TenantList(tenants:))
}

fn create_tenant_response_decoder() -> Decoder(TenantWithSecrets) {
  use tenant <- decode.field("tenant", tenant_with_secrets_decoder())
  decode.success(tenant)
}

fn regenerate_response_decoder() -> Decoder(RegenerateResponse) {
  use secret <- decode.field("secret", decode.string)
  decode.success(RegenerateResponse(secret:))
}

fn delete_response_decoder() -> Decoder(DeleteResponse) {
  use message <- decode.field("message", decode.string)
  decode.success(DeleteResponse(message:))
}

/// List all tenants
pub fn list_tenants(
  token: String,
  on_response: fn(Result(TenantList, ApiError)) -> msg,
) -> Effect(msg) {
  get_json(
    api_base <> "/tenants",
    Some(token),
    tenant_list_decoder(),
    on_response,
  )
}

/// Get a single tenant (no secrets)
pub fn get_tenant(
  token: String,
  tenant_id: String,
  on_response: fn(Result(Tenant, ApiError)) -> msg,
) -> Effect(msg) {
  let tenant_wrapper_decoder = {
    use tenant <- decode.field("tenant", tenant_decoder())
    decode.success(tenant)
  }

  get_json(
    api_base <> "/tenants/" <> tenant_id,
    Some(token),
    tenant_wrapper_decoder,
    on_response,
  )
}

/// Create a new tenant (returns secrets)
pub fn create_tenant(
  token: String,
  name: String,
  on_response: fn(Result(TenantWithSecrets, ApiError)) -> msg,
) -> Effect(msg) {
  let body = json.object([#("name", json.string(name))])

  post_json_with_token(
    api_base <> "/tenants",
    body,
    Some(token),
    create_tenant_response_decoder(),
    on_response,
  )
}

/// Regenerate a specific secret slot (1 or 2)
pub fn regenerate_secret(
  token: String,
  tenant_id: String,
  slot: Int,
  on_response: fn(Result(RegenerateResponse, ApiError)) -> msg,
) -> Effect(msg) {
  let url =
    api_base
    <> "/tenants/"
    <> tenant_id
    <> "/secrets/"
    <> int.to_string(slot)

  post_json_with_token(
    url,
    json.object([]),
    Some(token),
    regenerate_response_decoder(),
    on_response,
  )
}

/// Delete a tenant
pub fn delete_tenant(
  token: String,
  tenant_id: String,
  on_response: fn(Result(DeleteResponse, ApiError)) -> msg,
) -> Effect(msg) {
  delete_json(
    api_base <> "/tenants/" <> tenant_id,
    Some(token),
    delete_response_decoder(),
    on_response,
  )
}
```

Also add `import gleam/int` to the imports at the top of the file (after `import gleam/http/response`).

**Step 2: Build to check for compile errors**

Run: `cd server/levee_admin && gleam build`
Expected: Compile errors in files that reference old types — that's expected and will be fixed in Tasks 6-7

**Step 3: Commit**

```bash
git add server/levee_admin/src/levee_admin/api.gleam
git commit -m "feat(admin): update API client for server-generated tenants

Tenant type now has id+name. New TenantWithSecrets for create response.
create_tenant takes only name. New regenerate_secret function.
Removed update_tenant."
```

---

### Task 6: Update Admin UI — Create and Detail pages

**Files:**
- Modify: `server/levee_admin/src/levee_admin/pages/tenant_new.gleam`
- Modify: `server/levee_admin/src/levee_admin/pages/tenant_detail.gleam`

**Step 1: Rewrite tenant_new.gleam**

Replace `server/levee_admin/src/levee_admin/pages/tenant_new.gleam`:

```gleam
//// Create tenant form page — only requires a name, server generates everything else.

import gleam/option.{type Option, None, Some}
import gleam/string
import lustre/attribute.{class, disabled, for, id, placeholder, type_, value}
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html.{a, button, div, form, h1, input, label, p, span, text}
import lustre/event

// ─────────────────────────────────────────────────────────────────────────────
// Model
// ─────────────────────────────────────────────────────────────────────────────

pub type FormState {
  Idle
  Submitting
  Error(String)
}

pub type Model {
  Model(
    name: String,
    state: FormState,
    pending_submit: Option(String),
  )
}

pub fn init() -> Model {
  Model(name: "", state: Idle, pending_submit: None)
}

pub fn start_loading(model: Model) -> Model {
  Model(..model, state: Submitting, pending_submit: None)
}

pub fn set_error(model: Model, error: String) -> Model {
  Model(..model, state: Error(error))
}

pub fn get_pending_submit(model: Model) -> Option(String) {
  model.pending_submit
}

// ─────────────────────────────────────────────────────────────────────────────
// Messages
// ─────────────────────────────────────────────────────────────────────────────

pub type Msg {
  UpdateName(String)
  Submit
}

// ─────────────────────────────────────────────────────────────────────────────
// Update
// ─────────────────────────────────────────────────────────────────────────────

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    UpdateName(name) -> #(Model(..model, name: name), effect.none())

    Submit -> {
      let trimmed = string.trim(model.name)
      case string.is_empty(trimmed) {
        True -> #(
          Model(..model, state: Error("Name is required")),
          effect.none(),
        )
        False -> #(
          Model(..model, pending_submit: Some(trimmed)),
          effect.none(),
        )
      }
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// View
// ─────────────────────────────────────────────────────────────────────────────

pub fn view(model: Model) -> Element(Msg) {
  let is_submitting = case model.state {
    Submitting -> True
    _ -> False
  }

  div([class("page tenant-new-page")], [
    div([class("page-header")], [
      a([class("back-link"), attribute.href("/admin/tenants")], [
        text("Back to Tenants"),
      ]),
      h1([class("page-title")], [text("Create Tenant")]),
    ]),
    div([class("card form-card")], [
      view_error(model.state),
      form([class("tenant-form"), event.on_submit(fn(_) { Submit })], [
        div([class("form-group")], [
          label([for("name")], [text("Name")]),
          input([
            type_("text"),
            id("name"),
            placeholder("My Application"),
            value(model.name),
            event.on_input(UpdateName),
            attribute.required(True),
          ]),
          p([class("form-help")], [
            text("A display name for this tenant. The tenant ID and secrets will be generated automatically."),
          ]),
        ]),
        button(
          [type_("submit"), class("btn btn-primary"), disabled(is_submitting)],
          [
            case is_submitting {
              True -> text("Creating...")
              False -> text("Create Tenant")
            },
          ],
        ),
      ]),
    ]),
  ])
}

fn view_error(state: FormState) -> Element(Msg) {
  case state {
    Error(message) ->
      div([class("alert alert-error")], [
        span([class("alert-icon")], [text("!")]),
        span([class("alert-message")], [text(message)]),
      ])
    _ -> element.none()
  }
}
```

**Step 2: Rewrite tenant_detail.gleam**

Replace `server/levee_admin/src/levee_admin/pages/tenant_detail.gleam`:

```gleam
//// Tenant detail page with dual secret display and per-slot regeneration.

import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/string
import lustre/attribute.{class, disabled, type_}
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html.{a, button, code, div, h1, h2, p, span, text}
import lustre/event

// ─────────────────────────────────────────────────────────────────────────────
// Model
// ─────────────────────────────────────────────────────────────────────────────

pub type PageState {
  Loading
  Loaded
  NotFound
  Error(String)
}

pub type SecretSlotState {
  SlotIdle
  SlotConfirming
  SlotSubmitting
  SlotSuccess(String)
  SlotError(String)
}

pub type DeleteState {
  DeleteHidden
  DeleteConfirming(confirmation_input: String)
  DeleteSubmitting
  DeleteError(String)
}

pub type Model {
  Model(
    tenant_id: String,
    tenant_name: String,
    state: PageState,
    secret1_visible: Bool,
    secret2_visible: Bool,
    secret1_value: String,
    secret2_value: String,
    secret1_state: SecretSlotState,
    secret2_state: SecretSlotState,
    delete_state: DeleteState,
    pending_regenerate: Option(Int),
    pending_delete: Bool,
  )
}

pub fn init(tenant_id: String) -> Model {
  Model(
    tenant_id: tenant_id,
    tenant_name: "",
    state: Loading,
    secret1_visible: False,
    secret2_visible: False,
    secret1_value: "",
    secret2_value: "",
    secret1_state: SlotIdle,
    secret2_state: SlotIdle,
    delete_state: DeleteHidden,
    pending_regenerate: None,
    pending_delete: False,
  )
}

pub fn set_loaded(model: Model, name: String) -> Model {
  Model(..model, state: Loaded, tenant_name: name)
}

pub fn set_loaded_with_secrets(
  model: Model,
  name: String,
  secret1: String,
  secret2: String,
) -> Model {
  Model(
    ..model,
    state: Loaded,
    tenant_name: name,
    secret1_value: secret1,
    secret2_value: secret2,
    secret1_visible: True,
    secret2_visible: True,
  )
}

pub fn set_not_found(model: Model) -> Model {
  Model(..model, state: NotFound)
}

pub fn set_error(model: Model, error: String) -> Model {
  Model(..model, state: Error(error))
}

pub fn get_pending_regenerate(model: Model) -> Option(Int) {
  model.pending_regenerate
}

pub fn start_regenerate_loading(model: Model, slot: Int) -> Model {
  case slot {
    1 -> Model(..model, secret1_state: SlotSubmitting, pending_regenerate: None)
    _ -> Model(..model, secret2_state: SlotSubmitting, pending_regenerate: None)
  }
}

pub fn set_regenerate_success(model: Model, slot: Int, new_secret: String) -> Model {
  case slot {
    1 ->
      Model(
        ..model,
        secret1_state: SlotSuccess("Secret 1 regenerated"),
        secret1_value: new_secret,
        secret1_visible: True,
      )
    _ ->
      Model(
        ..model,
        secret2_state: SlotSuccess("Secret 2 regenerated"),
        secret2_value: new_secret,
        secret2_visible: True,
      )
  }
}

pub fn set_regenerate_error(model: Model, slot: Int, error: String) -> Model {
  case slot {
    1 -> Model(..model, secret1_state: SlotError(error))
    _ -> Model(..model, secret2_state: SlotError(error))
  }
}

pub fn start_delete_loading(model: Model) -> Model {
  Model(..model, delete_state: DeleteSubmitting, pending_delete: False)
}

pub fn get_pending_delete(model: Model) -> Bool {
  model.pending_delete
}

pub fn set_delete_error(model: Model, error: String) -> Model {
  Model(..model, delete_state: DeleteError(error))
}

// ─────────────────────────────────────────────────────────────────────────────
// Messages
// ─────────────────────────────────────────────────────────────────────────────

pub type Msg {
  ToggleSecret1Visible
  ToggleSecret2Visible
  RequestRegenerate(Int)
  ConfirmRegenerate(Int)
  CancelRegenerate(Int)
  ShowDeleteConfirm
  HideDeleteConfirm
  UpdateDeleteConfirmation(String)
  ConfirmDelete
}

// ─────────────────────────────────────────────────────────────────────────────
// Update
// ─────────────────────────────────────────────────────────────────────────────

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    ToggleSecret1Visible -> #(
      Model(..model, secret1_visible: !model.secret1_visible),
      effect.none(),
    )

    ToggleSecret2Visible -> #(
      Model(..model, secret2_visible: !model.secret2_visible),
      effect.none(),
    )

    RequestRegenerate(slot) -> {
      case slot {
        1 -> #(Model(..model, secret1_state: SlotConfirming), effect.none())
        _ -> #(Model(..model, secret2_state: SlotConfirming), effect.none())
      }
    }

    ConfirmRegenerate(slot) -> #(
      Model(..model, pending_regenerate: Some(slot)),
      effect.none(),
    )

    CancelRegenerate(slot) -> {
      case slot {
        1 -> #(Model(..model, secret1_state: SlotIdle), effect.none())
        _ -> #(Model(..model, secret2_state: SlotIdle), effect.none())
      }
    }

    ShowDeleteConfirm -> #(
      Model(..model, delete_state: DeleteConfirming("")),
      effect.none(),
    )

    HideDeleteConfirm -> #(
      Model(..model, delete_state: DeleteHidden),
      effect.none(),
    )

    UpdateDeleteConfirmation(input) -> #(
      Model(..model, delete_state: DeleteConfirming(input)),
      effect.none(),
    )

    ConfirmDelete -> {
      case model.delete_state {
        DeleteConfirming(input) if input == model.tenant_id -> {
          #(Model(..model, pending_delete: True), effect.none())
        }
        _ -> #(model, effect.none())
      }
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// View
// ─────────────────────────────────────────────────────────────────────────────

pub fn view(model: Model) -> Element(Msg) {
  div([class("page tenant-detail-page")], [
    div([class("page-header")], [
      a([class("back-link"), attribute.href("/admin/tenants")], [
        text("Back to Tenants"),
      ]),
      h1([class("page-title")], [text("Tenant: " <> model.tenant_name)]),
    ]),
    view_content(model),
  ])
}

fn view_content(model: Model) -> Element(Msg) {
  case model.state {
    Loading ->
      div([class("loading-state")], [p([], [text("Loading tenant...")])])

    NotFound ->
      div([class("empty-state card")], [
        p([], [text("Tenant not found.")]),
        a([attribute.href("/admin/tenants")], [text("Back to Tenants")]),
      ])

    Error(message) ->
      div([class("error-state")], [
        div([class("alert alert-error")], [
          span([class("alert-icon")], [text("!")]),
          span([class("alert-message")], [text(message)]),
        ]),
      ])

    Loaded ->
      div([class("tenant-detail-content")], [
        view_info(model),
        view_secret_card(model, 1),
        view_secret_card(model, 2),
        view_delete_section(model),
      ])
  }
}

fn view_info(model: Model) -> Element(Msg) {
  div([class("card")], [
    h2([], [text("Tenant Information")]),
    div([class("detail-row")], [
      span([class("detail-label")], [text("ID")]),
      span([class("detail-value")], [text(model.tenant_id)]),
    ]),
    div([class("detail-row")], [
      span([class("detail-label")], [text("Name")]),
      span([class("detail-value")], [text(model.tenant_name)]),
    ]),
  ])
}

fn view_secret_card(model: Model, slot: Int) -> Element(Msg) {
  let #(slot_state, secret_value, is_visible) = case slot {
    1 -> #(model.secret1_state, model.secret1_value, model.secret1_visible)
    _ -> #(model.secret2_state, model.secret2_value, model.secret2_visible)
  }

  let toggle_msg = case slot {
    1 -> ToggleSecret1Visible
    _ -> ToggleSecret2Visible
  }

  div([class("card")], [
    h2([], [text("Secret " <> int.to_string(slot))]),
    view_slot_status(slot_state),
    case string.is_empty(secret_value) {
      True ->
        p([class("form-help")], [text("Secret value is hidden. Regenerate to see the new value.")])
      False ->
        div([class("secret-display")], [
          code([class("secret-value")], [
            text(case is_visible {
              True -> secret_value
              False -> "••••••••••••••••••••••••••••••••"
            }),
          ]),
          button(
            [class("btn btn-secondary btn-sm"), event.on_click(toggle_msg)],
            [text(case is_visible {
              True -> "Hide"
              False -> "Show"
            })],
          ),
        ]),
    },
    view_regenerate_section(slot, slot_state),
  ])
}

fn view_slot_status(state: SecretSlotState) -> Element(Msg) {
  case state {
    SlotSuccess(message) ->
      div([class("alert alert-success")], [
        span([class("alert-message")], [text(message)]),
      ])
    SlotError(message) ->
      div([class("alert alert-error")], [
        span([class("alert-icon")], [text("!")]),
        span([class("alert-message")], [text(message)]),
      ])
    _ -> element.none()
  }
}

fn view_regenerate_section(slot: Int, state: SecretSlotState) -> Element(Msg) {
  case state {
    SlotConfirming ->
      div([class("regenerate-confirm")], [
        p([class("delete-warning")], [
          text("This will invalidate tokens signed with this secret. Continue?"),
        ]),
        div([class("delete-actions")], [
          button(
            [class("btn btn-danger"), event.on_click(ConfirmRegenerate(slot))],
            [text("Regenerate")],
          ),
          button(
            [class("btn btn-secondary"), event.on_click(CancelRegenerate(slot))],
            [text("Cancel")],
          ),
        ]),
      ])

    SlotSubmitting ->
      p([class("loading")], [text("Regenerating...")])

    _ ->
      button(
        [class("btn btn-primary"), event.on_click(RequestRegenerate(slot))],
        [text("Regenerate Secret " <> int.to_string(slot))],
      )
  }
}

fn view_delete_section(model: Model) -> Element(Msg) {
  div([class("card danger-card")], [
    h2([], [text("Danger Zone")]),
    case model.delete_state {
      DeleteHidden ->
        button(
          [class("btn btn-danger"), event.on_click(ShowDeleteConfirm)],
          [text("Delete Tenant")],
        )

      DeleteConfirming(confirmation) -> {
        let matches = confirmation == model.tenant_id
        div([class("delete-confirm")], [
          p([class("delete-warning")], [
            text("This action cannot be undone. Type the tenant ID to confirm:"),
          ]),
          p([class("delete-tenant-id")], [text(model.tenant_id)]),
          div([class("form-group")], [
            html.input([
              type_("text"),
              attribute.placeholder("Type tenant ID to confirm"),
              attribute.value(confirmation),
              event.on_input(UpdateDeleteConfirmation),
              class("delete-confirm-input"),
            ]),
          ]),
          div([class("delete-actions")], [
            button(
              [class("btn btn-danger"), disabled(!matches), event.on_click(ConfirmDelete)],
              [text("Delete Tenant")],
            ),
            button(
              [class("btn btn-secondary"), event.on_click(HideDeleteConfirm)],
              [text("Cancel")],
            ),
          ]),
        ])
      }

      DeleteSubmitting ->
        p([class("loading")], [text("Deleting tenant...")])

      DeleteError(message) ->
        div([], [
          div([class("alert alert-error")], [
            span([class("alert-icon")], [text("!")]),
            span([class("alert-message")], [text(message)]),
          ]),
          button(
            [class("btn btn-secondary"), event.on_click(HideDeleteConfirm)],
            [text("Cancel")],
          ),
        ])
    },
  ])
}
```

**Step 2: Build the admin UI**

Run: `cd server/levee_admin && gleam build`
Expected: Compile errors in main app — fixed in next task

**Step 3: Commit**

```bash
git add server/levee_admin/src/levee_admin/pages/tenant_new.gleam server/levee_admin/src/levee_admin/pages/tenant_detail.gleam
git commit -m "feat(admin): simplified create form and dual-secret detail page

Create form only requires name. Detail page shows both secret slots
with show/hide toggle and per-slot regenerate with confirmation."
```

---

### Task 7: Update Admin UI — main app, dashboard, tenants list, and CSS

**Files:**
- Modify: `server/levee_admin/src/levee_admin.gleam`
- Modify: `server/levee_admin/src/levee_admin/pages/tenants.gleam`
- Modify: `server/levee_admin/src/levee_admin/pages/dashboard.gleam`
- Modify: `server/priv/static/admin/index.html` (add CSS for secret display)

**Step 1: Update tenants.gleam**

Update the `Tenant` type in `server/levee_admin/src/levee_admin/pages/tenants.gleam` to include `name`:

Change `Tenant(id: String)` to `Tenant(id: String, name: String)`.

Update the tenant list view to show name alongside ID. In the `view_content` function, update the tenant row rendering to show both:

```gleam
li([class("tenant-row")], [
  a([href("/admin/tenants/" <> tenant.id)], [
    span([class("tenant-name")], [text(tenant.name)]),
    span([class("tenant-id")], [text(tenant.id)]),
  ]),
])
```

**Step 2: Update dashboard.gleam**

Same change: `Tenant(id: String)` → `Tenant(id: String, name: String)`.

Update preview rendering to show name:

```gleam
li([class("tenant-item")], [
  a([href("/admin/tenants/" <> tenant.id)], [
    text(tenant.name),
    span([class("tenant-id-small")], [text(" (" <> tenant.id <> ")")]),
  ]),
])
```

**Step 3: Update main app (levee_admin.gleam)**

Major changes needed in `server/levee_admin/src/levee_admin.gleam`:

1. Replace `UpdateTenantResponse` message with `RegenerateSecretResponse(Int, Result(api.RegenerateResponse, api.ApiError))` (the Int tracks which slot)

2. Replace `CreateTenantResponse(Result(api.TenantResponse, api.ApiError))` with `CreateTenantResponse(Result(api.TenantWithSecrets, api.ApiError))`

3. In `TenantNewMsg` handler: change `api.create_tenant(token, data.tenant_id, data.secret, ...)` to `api.create_tenant(token, data, ...)`  where `data` is the name string from `get_pending_submit`

4. In `TenantDetailMsg` handler: replace pending_update logic with pending_regenerate:
   ```gleam
   case tenant_detail.get_pending_regenerate(detail_model), model.session_token {
     Some(slot), Some(token) -> {
       let detail_model = tenant_detail.start_regenerate_loading(detail_model, slot)
       let api_effect = api.regenerate_secret(token, detail_model.tenant_id, slot, fn(result) {
         RegenerateSecretResponse(slot, result)
       })
       #(Model(..model, tenant_detail: detail_model), api_effect)
     }
     _, _ -> // check pending_delete next...
   }
   ```

5. In `TenantsResponse` handler: map tenants with name:
   ```gleam
   list.map(tenant_list.tenants, fn(t) { tenants.Tenant(id: t.id, name: t.name) })
   ```

6. In `DashboardTenantsResponse` handler: same mapping with name.

7. In `CreateTenantResponse(Ok(tenant_with_secrets))`: navigate to detail and set loaded with secrets:
   ```gleam
   let detail_model = tenant_detail.init(tenant_with_secrets.id)
     |> tenant_detail.set_loaded_with_secrets(
       tenant_with_secrets.name,
       tenant_with_secrets.secret1,
       tenant_with_secrets.secret2,
     )
   let model = Model(..model, tenant_new: tenant_new.init(), tenant_detail: detail_model)
   #(model, modem.push("/admin/tenants/" <> tenant_with_secrets.id, None, None))
   ```

8. In `GetTenantResponse(Ok(tenant))`: use `tenant_detail.set_loaded(model.tenant_detail, tenant.name)`

9. Add `RegenerateSecretResponse` handlers:
   ```gleam
   RegenerateSecretResponse(slot, Ok(response)) -> {
     let detail_model = tenant_detail.set_regenerate_success(model.tenant_detail, slot, response.secret)
     #(Model(..model, tenant_detail: detail_model), effect.none())
   }
   RegenerateSecretResponse(slot, Error(_error)) -> {
     let detail_model = tenant_detail.set_regenerate_error(model.tenant_detail, slot, "Failed to regenerate secret")
     #(Model(..model, tenant_detail: detail_model), effect.none())
   }
   ```

**Step 4: Add CSS for secret display**

In `server/priv/static/admin/index.html`, add before the closing `</style>` tag:

```css
    /* Secret display */
    .secret-display { display: flex; align-items: center; gap: 0.75rem; margin-bottom: 1rem; }
    .secret-value { font-size: 0.8125rem; background: var(--color-gray-100); padding: 0.5rem 0.75rem; border-radius: 0.375rem; word-break: break-all; flex: 1; }
    .btn-sm { padding: 0.375rem 0.75rem; font-size: 0.8125rem; }
    .regenerate-confirm { margin-top: 0.75rem; padding-top: 0.75rem; border-top: 1px solid var(--color-gray-200); }
    .tenant-name { font-weight: 500; }
    .tenant-id-small { color: var(--color-gray-500); font-family: monospace; font-size: 0.8125rem; }
```

**Step 5: Build admin UI**

Run: `cd server/levee_admin && gleam build`
Expected: Compiles successfully

**Step 6: Run full test suite**

Run: `cd server && mix test`
Expected: All pass

**Step 7: Commit**

```bash
git add server/levee_admin/src/ server/priv/static/admin/index.html
git commit -m "feat(admin): wire updated tenant pages into main app

Dashboard and list pages show tenant name. Create flow sends only
name, receives and displays generated ID + secrets. Detail page has
per-slot regenerate with confirmation and show/hide toggle."
```

---

### Task 8: Final verification and cleanup

**Step 1: Run the full test suite**

Run: `cd server && mix test`
Expected: All tests pass

**Step 2: Format code**

Run: `cd server && mix format`
Run: `cd server/levee_admin && gleam format`

**Step 3: Build everything**

Run: `cd server && mix compile`
Run: `cd server/levee_admin && gleam build`

**Step 4: Manual smoke test**

Run: `cd server && mix phx.server`
Navigate to `http://localhost:4000/admin`, log in, create a tenant (only enter a name), verify ID and secrets are shown, regenerate a secret, verify the new value appears.

**Step 5: Commit any formatting changes**

```bash
git add -A
git commit -m "style(admin): format code"
```
