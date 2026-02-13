defmodule LeveeWeb.SummaryChannelTest do
  use LeveeWeb.WebSocketCase

  alias Levee.Auth.JWT
  alias Levee.Auth.TenantSecrets

  @tenant_id "test-tenant-summary"

  setup do
    # Register tenant for JWT auth
    TenantSecrets.register_tenant(@tenant_id, "test-secret-for-summary-tests")

    # Ensure application is started
    {:ok, _} = Application.ensure_all_started(:levee)

    document_id = "doc-#{System.unique_integer([:positive])}"
    topic = "document:#{@tenant_id}:#{document_id}"

    # Connect WebSocket and join topic
    ws = ws_connect()
    join_ref = ws_join(ws, topic)

    # Generate JWT token for tests with summary:write scope
    {:ok, token} = JWT.generate_test_token(@tenant_id, document_id, "test-user")

    on_exit(fn -> TenantSecrets.unregister_tenant(@tenant_id) end)

    {:ok, ws: ws, join_ref: join_ref, document_id: document_id, topic: topic, token: token}
  end

  # Helper: send connect_document and assert success
  defp do_connect_document(ws, join_ref, topic, tenant_id, document_id, token, opts \\ []) do
    mode = Keyword.get(opts, :mode, "write")
    user_id = Keyword.get(opts, :user_id, "test-user")
    scopes = Keyword.get(opts, :scopes, ["doc:read", "doc:write", "summary:write"])

    connect_msg = %{
      "tenantId" => tenant_id,
      "id" => document_id,
      "token" => token,
      "client" => %{
        "user" => %{"id" => user_id},
        "mode" => mode,
        "details" => %{"capabilities" => %{"interactive" => true}},
        "permission" => scopes,
        "scopes" => scopes
      },
      "mode" => mode,
      "versions" => ["^0.1.0"]
    }

    ref = make_ref_string()
    ws_push(ws, join_ref, ref, topic, "connect_document", connect_msg)
    assert_ws_push("connect_document_success")
  end

  describe "summary ops through channel" do
    setup %{
      ws: ws,
      join_ref: join_ref,
      topic: topic,
      document_id: document_id,
      token: token
    } do
      response = do_connect_document(ws, join_ref, topic, @tenant_id, document_id, token)
      {:ok, client_id: response["clientId"]}
    end

    test "channel pushes summaryAck as separate event", %{
      ws: ws,
      join_ref: join_ref,
      topic: topic,
      client_id: client_id
    } do
      # Clear any pending messages
      flush_ws_messages()

      summary_handle = "channel-test-summary-#{System.unique_integer([:positive])}"

      summarize_op = %{
        "clientSequenceNumber" => 1,
        "referenceSequenceNumber" => 0,
        "type" => "summarize",
        "contents" => %{
          "handle" => summary_handle,
          "message" => "Channel test summary",
          "parents" => [],
          "head" => "tree-sha-channel"
        }
      }

      ref = make_ref_string()

      ws_push(ws, join_ref, ref, topic, "submitOp", %{
        "clientId" => client_id,
        "messageBatches" => [[summarize_op]]
      })

      # Should receive the summarize op in regular ops
      op_message = assert_ws_push("op")
      ops = op_message["op"]

      # The regular ops should include the sequenced summarize but NOT the summaryAck
      assert Enum.any?(ops, fn op -> op["type"] == "summarize" end)
      refute Enum.any?(ops, fn op -> op["type"] == "summaryAck" end)

      # summaryAck should be pushed as a separate event
      ack_message = assert_ws_push("summaryAck")
      assert ack_message["type"] == "summaryAck"
      assert ack_message["contents"]["handle"] == summary_handle
    end

    test "connect_document_success includes summaryContext after summary", %{
      ws: _ws,
      join_ref: _join_ref,
      topic: topic,
      document_id: document_id,
      token: token,
      client_id: _client_id
    } do
      # Connect a second client and submit a summary
      ws2 = ws_connect()
      join_ref2 = ws_join(ws2, topic)

      response2 =
        do_connect_document(ws2, join_ref2, topic, @tenant_id, document_id, token,
          user_id: "test-user-2"
        )

      client2_id = response2["clientId"]

      # Now client2 submits a summary
      summary_handle = "context-test-#{System.unique_integer([:positive])}"

      summarize_op = %{
        "clientSequenceNumber" => 1,
        "referenceSequenceNumber" => 0,
        "type" => "summarize",
        "contents" => %{
          "handle" => summary_handle,
          "message" => "Summary for context test",
          "parents" => [],
          "head" => "tree-sha-context"
        }
      }

      ref = make_ref_string()

      ws_push(ws2, join_ref2, ref, topic, "submitOp", %{
        "clientId" => client2_id,
        "messageBatches" => [[summarize_op]]
      })

      # Wait for summary to be processed
      assert_ws_push("summaryAck")

      # Now connect a third client and verify summaryContext is included
      ws3 = ws_connect()
      join_ref3 = ws_join(ws3, topic)

      response3 =
        do_connect_document(ws3, join_ref3, topic, @tenant_id, document_id, token,
          user_id: "test-user-3",
          scopes: ["doc:read", "doc:write"]
        )

      # Response should include summaryContext
      assert Map.has_key?(response3, "summaryContext")
      assert response3["summaryContext"]["handle"] == summary_handle
    end

    test "invalid summarize op returns nack", %{
      ws: ws,
      join_ref: join_ref,
      topic: topic,
      client_id: client_id
    } do
      flush_ws_messages()

      # Submit invalid summarize op (missing required fields)
      invalid_summarize = %{
        "clientSequenceNumber" => 1,
        "referenceSequenceNumber" => 0,
        "type" => "summarize",
        "contents" =>
          %{
            # Missing handle, message, parents, head
          }
      }

      ref = make_ref_string()

      ws_push(ws, join_ref, ref, topic, "submitOp", %{
        "clientId" => client_id,
        "messageBatches" => [[invalid_summarize]]
      })

      # Should receive a nack
      nack_response = assert_ws_push("nack")
      assert is_list(nack_response["nacks"])
      nack = List.first(nack_response["nacks"])
      assert nack["content"]["code"] == 400
      assert nack["content"]["message"] =~ "summarize"
    end
  end
end
