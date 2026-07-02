defmodule LeveeWeb.VersionControllerTest do
  use LeveeWeb.ConnCase

  alias Levee.Auth.JWT
  alias Levee.Auth.TenantSecrets
  alias Levee.Storage

  @tenant_id "version-test-tenant"
  @user_id "test-user"

  setup do
    {:ok, _} = Application.ensure_all_started(:levee)

    TenantSecrets.register_tenant(@tenant_id, "test-secret-key-for-version-tests")
    on_exit(fn -> TenantSecrets.unregister_tenant(@tenant_id) end)

    :ok
  end

  defp generate_token(document_id) do
    {:ok, token} =
      JWT.generate_test_token(@tenant_id, document_id, @user_id, scopes: ["doc:read"])

    token
  end

  defp store_summary(document_id, handle, sequence_number) do
    {:ok, _} =
      Storage.store_summary(@tenant_id, document_id, %{
        handle: handle,
        sequence_number: sequence_number,
        tree_sha: handle,
        commit_sha: nil,
        parent_handle: nil,
        message: "summary at #{sequence_number}"
      })
  end

  describe "GET /versions/:tenant_id/:id" do
    test "lists summary versions newest first", %{conn: conn} do
      document_id = "versions-doc-#{System.unique_integer([:positive])}"
      store_summary(document_id, "tree-a", 10)
      store_summary(document_id, "tree-b", 25)
      store_summary(document_id, "tree-c", 40)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{generate_token(document_id)}")
        |> get("/versions/#{@tenant_id}/#{document_id}")

      assert %{"value" => versions} = json_response(conn, 200)
      assert Enum.map(versions, & &1["handle"]) == ["tree-c", "tree-b", "tree-a"]
      assert Enum.map(versions, & &1["sequenceNumber"]) == [40, 25, 10]
    end

    test "caps the list at count newest versions", %{conn: conn} do
      document_id = "versions-doc-#{System.unique_integer([:positive])}"
      store_summary(document_id, "tree-a", 10)
      store_summary(document_id, "tree-b", 25)
      store_summary(document_id, "tree-c", 40)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{generate_token(document_id)}")
        |> get("/versions/#{@tenant_id}/#{document_id}?count=2")

      assert %{"value" => versions} = json_response(conn, 200)
      assert Enum.map(versions, & &1["handle"]) == ["tree-c", "tree-b"]
    end

    test "returns an empty list for a never-summarized document", %{conn: conn} do
      document_id = "versions-doc-#{System.unique_integer([:positive])}"

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{generate_token(document_id)}")
        |> get("/versions/#{@tenant_id}/#{document_id}")

      assert %{"value" => []} = json_response(conn, 200)
    end

    test "requires authentication", %{conn: conn} do
      conn = get(conn, "/versions/#{@tenant_id}/some-doc")

      assert conn.status == 401
    end
  end
end
