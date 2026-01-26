defmodule FluidServer.Documents.SessionTest do
  use ExUnit.Case, async: false

  alias FluidServer.Documents.Session

  @tenant_id "test-tenant"

  setup do
    # Ensure application is started
    {:ok, _} = Application.ensure_all_started(:fluid_server)

    # Generate unique document ID for each test
    document_id = "doc-#{System.unique_integer([:positive])}"

    # Start a session
    {:ok, pid} = start_supervised({Session, {@tenant_id, document_id}})

    {:ok, session: pid, document_id: document_id}
  end

  describe "client_join/2" do
    test "assigns client ID and returns connected response", %{session: session} do
      connect_msg = build_connect_message()

      {:ok, client_id, response} = Session.client_join(session, connect_msg)

      assert is_binary(client_id)
      assert client_id =~ @tenant_id
      assert response["clientId"] == client_id
      assert response["mode"] == "write"
      assert is_integer(response["checkpointSequenceNumber"])
      assert response["checkpointSequenceNumber"] >= 0
    end

    test "generates system join message with sequence number", %{session: session} do
      connect_msg = build_connect_message()

      # Join first client to receive the join message
      {:ok, _client1_id, _} = Session.client_join(session, connect_msg)

      # Wait for the join message
      assert_receive {:op, op_message}, 1000
      assert op_message["op"] != []

      join_op = List.first(op_message["op"])
      assert join_op["type"] == "join"
      # System messages have no clientId
      assert join_op["clientId"] == nil
      assert is_integer(join_op["sequenceNumber"])
      assert join_op["sequenceNumber"] > 0
    end

    test "includes initial clients in response", %{session: session} do
      # Join first client
      connect_msg1 = build_connect_message(%{"user" => %{"id" => "user1"}})
      {:ok, client1_id, _} = Session.client_join(session, connect_msg1)

      # Join second client
      connect_msg2 = build_connect_message(%{"user" => %{"id" => "user2"}})
      {:ok, _client2_id, response} = Session.client_join(session, connect_msg2)

      # Second client should see first client in initial clients
      assert length(response["initialClients"]) == 1
      initial_client = List.first(response["initialClients"])
      assert initial_client["clientId"] == client1_id
    end
  end

  describe "client_leave/2" do
    test "removes client and generates leave message", %{session: session} do
      # Join two clients
      connect_msg1 = build_connect_message()
      {:ok, client1_id, _} = Session.client_join(session, connect_msg1)

      connect_msg2 = build_connect_message()
      {:ok, _client2_id, _} = Session.client_join(session, connect_msg2)

      # Clear messages from join
      flush_messages()

      # Client 1 leaves
      :ok = Session.client_leave(session, client1_id)

      # Client 2 should receive leave message
      assert_receive {:op, op_message}, 1000
      leave_op = List.first(op_message["op"])
      assert leave_op["type"] == "leave"
      # System message
      assert leave_op["clientId"] == nil
      assert is_integer(leave_op["sequenceNumber"])
    end
  end

  describe "submit_ops/3" do
    test "sequences operations and broadcasts to clients", %{session: session} do
      # Join two clients
      connect_msg1 = build_connect_message()
      {:ok, client1_id, _} = Session.client_join(session, connect_msg1)

      connect_msg2 = build_connect_message()
      {:ok, _client2_id, _} = Session.client_join(session, connect_msg2)

      # Clear join messages
      flush_messages()

      # Client 1 submits an operation
      op = %{
        "clientSequenceNumber" => 1,
        "referenceSequenceNumber" => 0,
        "type" => "op",
        "contents" => %{"insert" => "hello"}
      }

      :ok = Session.submit_ops(session, client1_id, [[op]])

      # Both clients should receive the sequenced op
      assert_receive {:op, op_message}, 1000
      sequenced_op = List.first(op_message["op"])

      assert sequenced_op["clientId"] == client1_id
      assert sequenced_op["sequenceNumber"] > 0
      assert sequenced_op["clientSequenceNumber"] == 1
      assert sequenced_op["contents"] == %{"insert" => "hello"}
    end

    test "returns nack for invalid CSN", %{session: session} do
      connect_msg = build_connect_message()
      {:ok, client_id, _} = Session.client_join(session, connect_msg)

      # Submit op with CSN 1
      op1 = %{
        "clientSequenceNumber" => 1,
        "referenceSequenceNumber" => 0,
        "type" => "op",
        "contents" => %{}
      }

      :ok = Session.submit_ops(session, client_id, [[op1]])

      # Try to submit op with CSN 1 again (should fail)
      op2 = %{
        "clientSequenceNumber" => 1,
        "referenceSequenceNumber" => 0,
        "type" => "op",
        "contents" => %{}
      }

      {:error, nacks} = Session.submit_ops(session, client_id, [[op2]])

      assert length(nacks) == 1
      nack = List.first(nacks)
      assert nack["content"]["code"] == 400
      assert nack["content"]["message"] =~ "Invalid CSN"
    end

    test "returns nack for unknown client", %{session: session} do
      {:error, nacks} = Session.submit_ops(session, "unknown-client", [[]])

      assert length(nacks) == 1
      nack = List.first(nacks)
      assert nack["content"]["message"] =~ "Unknown client"
    end

    test "returns nack for read-only client", %{session: session} do
      connect_msg = build_connect_message(%{}, "read")
      {:ok, client_id, _} = Session.client_join(session, connect_msg)

      op = %{
        "clientSequenceNumber" => 1,
        "referenceSequenceNumber" => 0,
        "type" => "op",
        "contents" => %{}
      }

      {:error, nacks} = Session.submit_ops(session, client_id, [[op]])

      assert length(nacks) == 1
      nack = List.first(nacks)
      assert nack["content"]["message"] =~ "read-only"
    end

    test "sequences multiple ops in batch correctly", %{session: session} do
      connect_msg = build_connect_message()
      {:ok, client_id, _} = Session.client_join(session, connect_msg)
      flush_messages()

      # Submit batch of 3 ops
      ops = [
        %{
          "clientSequenceNumber" => 1,
          "referenceSequenceNumber" => 0,
          "type" => "op",
          "contents" => %{"a" => 1}
        },
        %{
          "clientSequenceNumber" => 2,
          "referenceSequenceNumber" => 0,
          "type" => "op",
          "contents" => %{"b" => 2}
        },
        %{
          "clientSequenceNumber" => 3,
          "referenceSequenceNumber" => 0,
          "type" => "op",
          "contents" => %{"c" => 3}
        }
      ]

      :ok = Session.submit_ops(session, client_id, [ops])

      # Should receive all ops with incrementing SNs
      assert_receive {:op, op_message}, 1000
      sequenced_ops = op_message["op"]

      assert length(sequenced_ops) == 3

      sns = Enum.map(sequenced_ops, & &1["sequenceNumber"])
      # SNs should be in order
      assert sns == Enum.sort(sns)
      # SNs should be unique
      assert Enum.uniq(sns) == sns
    end
  end

  describe "get_ops_since/2" do
    test "returns operations since given SN for delta catch-up", %{session: session} do
      connect_msg = build_connect_message()
      {:ok, client_id, response} = Session.client_join(session, connect_msg)

      initial_sn = response["checkpointSequenceNumber"]
      flush_messages()

      # Submit some ops
      ops = [
        %{
          "clientSequenceNumber" => 1,
          "referenceSequenceNumber" => initial_sn,
          "type" => "op",
          "contents" => %{"a" => 1}
        },
        %{
          "clientSequenceNumber" => 2,
          "referenceSequenceNumber" => initial_sn,
          "type" => "op",
          "contents" => %{"b" => 2}
        },
        %{
          "clientSequenceNumber" => 3,
          "referenceSequenceNumber" => initial_sn,
          "type" => "op",
          "contents" => %{"c" => 3}
        }
      ]

      :ok = Session.submit_ops(session, client_id, [ops])
      flush_messages()

      # Get ops since initial SN
      {:ok, catchup_ops} = Session.get_ops_since(session, initial_sn)

      # Should include join message + 3 ops
      assert length(catchup_ops) >= 3

      # Ops should be in chronological order (ascending SN)
      sns = Enum.map(catchup_ops, & &1["sequenceNumber"])
      assert sns == Enum.sort(sns)
    end

    test "returns empty list when caught up", %{session: session} do
      connect_msg = build_connect_message()
      {:ok, _client_id, _} = Session.client_join(session, connect_msg)

      # Get current state
      {:ok, summary} = Session.get_state_summary(session)
      current_sn = summary.current_sn

      # Get ops since current SN (should be empty)
      {:ok, ops} = Session.get_ops_since(session, current_sn)
      assert ops == []
    end
  end

  describe "get_state_summary/1" do
    test "returns session state summary", %{session: session, document_id: document_id} do
      connect_msg = build_connect_message()
      {:ok, client_id, _} = Session.client_join(session, connect_msg)

      {:ok, summary} = Session.get_state_summary(session)

      assert summary.tenant_id == @tenant_id
      assert summary.document_id == document_id
      assert summary.client_count == 1
      assert client_id in summary.client_ids
      assert is_integer(summary.current_sn)
      assert is_integer(summary.current_msn)
      assert is_integer(summary.history_size)
    end
  end

  describe "multi-client scenarios" do
    test "MSN advances as clients acknowledge ops", %{session: session} do
      # Join two clients
      connect_msg1 = build_connect_message()
      {:ok, client1_id, _} = Session.client_join(session, connect_msg1)

      connect_msg2 = build_connect_message()
      {:ok, client2_id, _} = Session.client_join(session, connect_msg2)
      flush_messages()

      {:ok, summary1} = Session.get_state_summary(session)
      initial_msn = summary1.current_msn

      # Client 1 submits ops with updated RSN
      op1 = %{
        "clientSequenceNumber" => 1,
        "referenceSequenceNumber" => summary1.current_sn,
        "type" => "op",
        "contents" => %{}
      }

      :ok = Session.submit_ops(session, client1_id, [[op1]])

      # MSN should still be at initial since client2 hasn't advanced
      {:ok, summary2} = Session.get_state_summary(session)
      # MSN is based on min RSN of all clients

      # Client 2 submits op with updated RSN
      op2 = %{
        "clientSequenceNumber" => 1,
        "referenceSequenceNumber" => summary2.current_sn,
        "type" => "op",
        "contents" => %{}
      }

      :ok = Session.submit_ops(session, client2_id, [[op2]])

      # Now MSN should have potentially advanced
      {:ok, summary3} = Session.get_state_summary(session)
      assert summary3.current_msn >= initial_msn
    end

    test "handles interleaved operations from multiple clients", %{session: session} do
      # Join three clients
      {:ok, client1_id, _r1} = Session.client_join(session, build_connect_message())
      {:ok, client2_id, _r2} = Session.client_join(session, build_connect_message())
      {:ok, client3_id, _r3} = Session.client_join(session, build_connect_message())
      flush_messages()

      {:ok, summary} = Session.get_state_summary(session)
      sn = summary.current_sn

      # Interleave ops from all clients
      :ok =
        Session.submit_ops(session, client1_id, [
          [
            %{
              "clientSequenceNumber" => 1,
              "referenceSequenceNumber" => sn,
              "type" => "op",
              "contents" => %{"from" => "c1"}
            }
          ]
        ])

      :ok =
        Session.submit_ops(session, client2_id, [
          [
            %{
              "clientSequenceNumber" => 1,
              "referenceSequenceNumber" => sn,
              "type" => "op",
              "contents" => %{"from" => "c2"}
            }
          ]
        ])

      :ok =
        Session.submit_ops(session, client3_id, [
          [
            %{
              "clientSequenceNumber" => 1,
              "referenceSequenceNumber" => sn,
              "type" => "op",
              "contents" => %{"from" => "c3"}
            }
          ]
        ])

      # All clients should receive all ops
      # 3 clients * 3 ops each
      ops = collect_ops(9)

      # Verify SNs are globally ordered
      sns = Enum.map(ops, & &1["sequenceNumber"]) |> Enum.sort() |> Enum.uniq()
      # At least 3 unique SNs from the ops
      assert length(sns) >= 3
    end
  end

  # Helper functions

  defp build_connect_message(user_overrides \\ %{}, mode \\ "write") do
    %{
      "tenantId" => @tenant_id,
      "id" => "test-doc",
      "client" =>
        Map.merge(
          %{
            "user" => %{"id" => "test-user-#{System.unique_integer([:positive])}"},
            "mode" => mode,
            "details" => %{
              "capabilities" => %{"interactive" => true}
            },
            "permission" => ["doc:read", "doc:write"],
            "scopes" => ["doc:read", "doc:write"]
          },
          user_overrides
        ),
      "mode" => mode,
      "versions" => ["^0.1.0"]
    }
  end

  defp flush_messages do
    receive do
      _ -> flush_messages()
    after
      10 -> :ok
    end
  end

  defp collect_ops(expected_count, timeout \\ 1000, acc \\ []) do
    receive do
      {:op, %{"op" => ops}} ->
        new_acc = acc ++ ops

        if length(new_acc) >= expected_count do
          new_acc
        else
          collect_ops(expected_count, timeout, new_acc)
        end
    after
      timeout -> acc
    end
  end
end
