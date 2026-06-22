defmodule LeveeWeb.SummaryChannelTest do
  use LeveeWeb.ChannelCase

  alias Levee.Auth.JWT
  alias Levee.Auth.TenantSecrets
  alias LeveeWeb.UserSocket
  alias LeveeWeb.DocumentChannel

  @tenant_id "test-tenant-summary"

  setup do
    # Register tenant for JWT auth
    TenantSecrets.register_tenant(@tenant_id, "test-secret-for-summary-tests")

    # Ensure application is started
    {:ok, _} = Application.ensure_all_started(:levee)

    document_id = "doc-#{System.unique_integer([:positive])}"
    topic = "document:#{@tenant_id}:#{document_id}"

    {:ok, _, socket} =
      UserSocket
      |> socket("user_id", %{})
      |> subscribe_and_join(DocumentChannel, topic)

    # Generate JWT token for tests with summary:write scope
    {:ok, token} = JWT.generate_test_token(@tenant_id, document_id, "test-user")

    on_exit(fn -> TenantSecrets.unregister_tenant(@tenant_id) end)

    {:ok, socket: socket, document_id: document_id, topic: topic, token: token}
  end

  describe "summary ops through channel" do
    setup %{socket: socket, document_id: document_id, token: token} do
      # Connect to document first
      connect_msg = %{
        "tenantId" => @tenant_id,
        "id" => document_id,
        "token" => token,
        "client" => %{
          "user" => %{"id" => "test-user"},
          "mode" => "write",
          "details" => %{"capabilities" => %{"interactive" => true}},
          "permission" => ["doc:read", "doc:write", "summary:write"],
          "scopes" => ["doc:read", "doc:write", "summary:write"]
        },
        "mode" => "write",
        "versions" => ["^0.1.0"]
      }

      push(socket, "connect_document", connect_msg)
      assert_push "connect_document_success", %{"clientId" => client_id}, 1_000

      {:ok, client_id: client_id}
    end

    test "channel pushes summaryAck as separate event", %{socket: socket, client_id: client_id} do
      # Clear any pending messages
      flush_push_messages()

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

      push(socket, "submitOp", %{
        "clientId" => client_id,
        "messageBatches" => [[summarize_op]]
      })

      # Should receive the summarize op in regular ops
      assert_push "op", op_message
      ops = op_message["op"]

      # The regular ops should include the sequenced summarize but NOT the summaryAck
      assert Enum.any?(ops, fn op -> op["type"] == "summarize" end)
      refute Enum.any?(ops, fn op -> op["type"] == "summaryAck" end)

      # summaryAck should be pushed as a separate event
      assert_push "summaryAck", ack_message
      assert ack_message["type"] == "summaryAck"
      assert ack_message["contents"]["handle"] == summary_handle
    end

    test "connect_document_success includes summaryContext after summary", %{
      socket: _socket,
      document_id: document_id,
      topic: topic,
      token: token,
      client_id: _client_id
    } do
      # First submit a summary using the existing connection
      # We need to get a fresh socket since we used the one from setup
      {:ok, _, socket2} =
        UserSocket
        |> socket("user_id_2", %{})
        |> subscribe_and_join(DocumentChannel, topic)

      connect_msg2 = %{
        "tenantId" => @tenant_id,
        "id" => document_id,
        "token" => token,
        "client" => %{
          "user" => %{"id" => "test-user-2"},
          "mode" => "write",
          "details" => %{"capabilities" => %{"interactive" => true}},
          "permission" => ["doc:read", "doc:write", "summary:write"],
          "scopes" => ["doc:read", "doc:write", "summary:write"]
        },
        "mode" => "write",
        "versions" => ["^0.1.0"]
      }

      push(socket2, "connect_document", connect_msg2)
      assert_push "connect_document_success", %{"clientId" => client2_id}

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

      push(socket2, "submitOp", %{
        "clientId" => client2_id,
        "messageBatches" => [[summarize_op]]
      })

      # Wait for summary to be processed
      assert_push "summaryAck", _ack

      # Now connect a third client and verify summaryContext is included
      {:ok, _, socket3} =
        UserSocket
        |> socket("user_id_3", %{})
        |> subscribe_and_join(DocumentChannel, topic)

      connect_msg3 = %{
        "tenantId" => @tenant_id,
        "id" => document_id,
        "token" => token,
        "client" => %{
          "user" => %{"id" => "test-user-3"},
          "mode" => "write",
          "details" => %{"capabilities" => %{"interactive" => true}},
          "permission" => ["doc:read", "doc:write"],
          "scopes" => ["doc:read", "doc:write"]
        },
        "mode" => "write",
        "versions" => ["^0.1.0"]
      }

      push(socket3, "connect_document", connect_msg3)
      assert_push "connect_document_success", response

      # Response should include summaryContext
      assert Map.has_key?(response, "summaryContext")
      assert response["summaryContext"]["handle"] == summary_handle
    end

    test "invalid summarize op returns nack", %{socket: socket, client_id: client_id} do
      flush_push_messages()

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

      push(socket, "submitOp", %{
        "clientId" => client_id,
        "messageBatches" => [[invalid_summarize]]
      })

      # Should receive a nack
      assert_push "nack", nack_response
      assert is_list(nack_response["nacks"])
      nack = List.first(nack_response["nacks"])
      assert nack["content"]["code"] == 400
      assert nack["content"]["message"] =~ "summarize"
    end
  end

  # Helper to clear pending push messages
  defp flush_push_messages do
    receive do
      %Phoenix.Socket.Message{} -> flush_push_messages()
    after
      50 -> :ok
    end
  end
end
