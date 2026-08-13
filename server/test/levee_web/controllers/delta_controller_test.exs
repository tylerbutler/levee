defmodule LeveeWeb.DeltaControllerTest do
  use LeveeWeb.ConnCase

  alias Levee.Auth.JWT
  alias Levee.Auth.TenantSecrets
  alias Levee.Storage

  @tenant_id "delta-controller-test-tenant"
  @user_id "test-user"

  setup do
    {:ok, _} = Application.ensure_all_started(:levee)

    TenantSecrets.register_tenant(@tenant_id, "test-secret-key-for-delta-controller-tests")
    on_exit(fn -> TenantSecrets.unregister_tenant(@tenant_id) end)

    document_id = "delta-controller-test-doc-#{System.unique_integer([:positive])}"
    {:ok, _} = Storage.create_document(@tenant_id, document_id, %{sequence_number: 0})

    {:ok, document_id: document_id}
  end

  defp read_token(document_id) do
    {:ok, token} =
      JWT.generate_test_token(@tenant_id, document_id, @user_id, scopes: ["doc:read"])

    token
  end

  defp authed(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  describe "GET /deltas/:tenant_id/:id" do
    test "op messages omit the data sidecar field", %{conn: conn, document_id: document_id} do
      {:ok, _} =
        Storage.store_delta(@tenant_id, document_id, %{
          sequence_number: 1,
          client_sequence_number: 1,
          minimum_sequence_number: 0,
          client_id: "client-1",
          reference_sequence_number: 0,
          type: "op",
          contents: %{"key" => "value"},
          metadata: nil,
          timestamp: 1_700_000_000_000
        })

      conn =
        conn
        |> authed(read_token(document_id))
        |> get("/deltas/#{@tenant_id}/#{document_id}")

      assert %{"value" => [message]} = json_response(conn, 200)

      assert message["sequenceNumber"] == 1
      assert message["clientSequenceNumber"] == 1
      assert message["minimumSequenceNumber"] == 0
      assert message["clientId"] == "client-1"
      assert message["referenceSequenceNumber"] == 0
      assert message["type"] == "op"
      assert message["contents"] == %{"key" => "value"}
      refute Map.has_key?(message, "data")
    end

    test "join messages include a JSON-stringified data sidecar field", %{
      conn: conn,
      document_id: document_id
    } do
      {:ok, _} =
        Storage.store_delta(@tenant_id, document_id, %{
          sequence_number: 2,
          client_sequence_number: -1,
          minimum_sequence_number: 0,
          client_id: nil,
          reference_sequence_number: 0,
          type: "join",
          contents: %{"clientId" => "client-2"},
          metadata: nil,
          timestamp: 1_700_000_001_000
        })

      conn =
        conn
        |> authed(read_token(document_id))
        |> get("/deltas/#{@tenant_id}/#{document_id}")

      assert %{"value" => [message]} = json_response(conn, 200)

      assert message["type"] == "join"
      assert message["data"] == Jason.encode!(%{"clientId" => "client-2"})
    end

    test "leave messages include a JSON-stringified data sidecar field", %{
      conn: conn,
      document_id: document_id
    } do
      {:ok, _} =
        Storage.store_delta(@tenant_id, document_id, %{
          sequence_number: 3,
          client_sequence_number: -1,
          minimum_sequence_number: 0,
          client_id: nil,
          reference_sequence_number: 0,
          type: "leave",
          contents: "client-2",
          metadata: nil,
          timestamp: 1_700_000_002_000
        })

      conn =
        conn
        |> authed(read_token(document_id))
        |> get("/deltas/#{@tenant_id}/#{document_id}")

      assert %{"value" => [message]} = json_response(conn, 200)

      assert message["type"] == "leave"
      assert message["data"] == Jason.encode!("client-2")
    end

    test "respects the from query parameter", %{conn: conn, document_id: document_id} do
      for sn <- 1..3 do
        {:ok, _} =
          Storage.store_delta(@tenant_id, document_id, %{
            sequence_number: sn,
            client_sequence_number: sn,
            minimum_sequence_number: 0,
            client_id: "client-1",
            reference_sequence_number: 0,
            type: "op",
            contents: %{"n" => sn},
            metadata: nil,
            timestamp: 1_700_000_000_000 + sn
          })
      end

      conn =
        conn
        |> authed(read_token(document_id))
        |> get("/deltas/#{@tenant_id}/#{document_id}?from=1")

      assert %{"value" => messages} = json_response(conn, 200)
      assert Enum.map(messages, & &1["sequenceNumber"]) == [2, 3]
    end
  end
end
