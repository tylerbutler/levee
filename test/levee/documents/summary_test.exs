defmodule Levee.Documents.SummaryTest do
  use ExUnit.Case, async: false

  alias Levee.Documents.Session
  alias Levee.Storage.ETS

  @tenant_id "test-tenant"

  setup do
    # Ensure application is started
    {:ok, _} = Application.ensure_all_started(:levee)

    # Generate unique document ID for each test
    document_id = "doc-#{System.unique_integer([:positive])}"

    # Start a session
    {:ok, pid} = start_supervised({Session, {@tenant_id, document_id}})

    {:ok, session: pid, document_id: document_id}
  end

  describe "summary op submission" do
    test "successfully processes summarize op and generates summaryAck", %{
      session: session,
      document_id: document_id
    } do
      # Join a client
      connect_msg = build_connect_message(document_id)
      {:ok, client_id, _} = Session.client_join(session, connect_msg)
      flush_messages()

      # Submit a summarize op
      summary_handle = "test-summary-handle-#{System.unique_integer([:positive])}"

      summarize_op = %{
        "clientSequenceNumber" => 1,
        "referenceSequenceNumber" => 0,
        "type" => "summarize",
        "contents" => %{
          "handle" => summary_handle,
          "message" => "Test summary",
          "parents" => [],
          "head" => "tree-sha-123"
        }
      }

      :ok = Session.submit_ops(session, client_id, [[summarize_op]])

      # Should receive the op message containing both the sequenced summarize op and summaryAck
      # Note: Session sends raw {:op, message} - the channel would split out summaryAck,
      # but in this direct test we receive the raw message
      assert_receive {:op, op_message}, 1000
      ops = op_message["op"]

      # Find the summarize op
      summarize = Enum.find(ops, fn op -> op["type"] == "summarize" end)
      assert summarize != nil
      assert summarize["clientId"] == client_id
      assert is_integer(summarize["sequenceNumber"])

      # Find the summaryAck in the same batch
      summary_ack = Enum.find(ops, fn op -> op["type"] == "summaryAck" end)
      assert summary_ack != nil
      assert summary_ack["type"] == "summaryAck"
      assert summary_ack["contents"]["handle"] == summary_handle

      assert summary_ack["contents"]["summaryProposal"]["summarySequenceNumber"] ==
               summarize["sequenceNumber"]
    end

    test "includes summary context on reconnection", %{session: session, document_id: document_id} do
      # Join first client and submit a summary
      connect_msg = build_connect_message(document_id)
      {:ok, client_id, _} = Session.client_join(session, connect_msg)
      flush_messages()

      summary_handle = "summary-for-reconnect-#{System.unique_integer([:positive])}"

      summarize_op = %{
        "clientSequenceNumber" => 1,
        "referenceSequenceNumber" => 0,
        "type" => "summarize",
        "contents" => %{
          "handle" => summary_handle,
          "message" => "Summary for reconnect test",
          "parents" => [],
          "head" => "tree-sha-456"
        }
      }

      :ok = Session.submit_ops(session, client_id, [[summarize_op]])
      flush_messages()

      # Now join a second client and check for summary context
      connect_msg2 = build_connect_message(document_id)
      {:ok, _client_id2, response} = Session.client_join(session, connect_msg2)

      # Response should include summaryContext
      assert Map.has_key?(response, "summaryContext")
      summary_context = response["summaryContext"]
      assert summary_context["handle"] == summary_handle
      assert is_integer(summary_context["sequenceNumber"])
    end

    test "returns nack for invalid summarize op (missing fields)", %{
      session: session,
      document_id: document_id
    } do
      connect_msg = build_connect_message(document_id)
      {:ok, client_id, _} = Session.client_join(session, connect_msg)
      flush_messages()

      # Submit summarize op missing required fields
      invalid_summarize_op = %{
        "clientSequenceNumber" => 1,
        "referenceSequenceNumber" => 0,
        "type" => "summarize",
        "contents" =>
          %{
            # Missing "handle", "message", "parents", "head"
          }
      }

      {:error, nacks} = Session.submit_ops(session, client_id, [[invalid_summarize_op]])

      assert length(nacks) == 1
      nack = List.first(nacks)
      assert nack["content"]["code"] == 400
      assert nack["content"]["message"] =~ "summarize"
    end

    test "summary is persisted to storage", %{session: session, document_id: document_id} do
      connect_msg = build_connect_message(document_id)
      {:ok, client_id, _} = Session.client_join(session, connect_msg)
      flush_messages()

      summary_handle = "persisted-summary-#{System.unique_integer([:positive])}"

      summarize_op = %{
        "clientSequenceNumber" => 1,
        "referenceSequenceNumber" => 0,
        "type" => "summarize",
        "contents" => %{
          "handle" => summary_handle,
          "message" => "Persisted summary",
          "parents" => [],
          "head" => "tree-sha-789"
        }
      }

      :ok = Session.submit_ops(session, client_id, [[summarize_op]])
      flush_messages()

      # Verify summary was stored
      {:ok, stored_summary} = ETS.get_summary(@tenant_id, document_id, summary_handle)
      assert stored_summary.handle == summary_handle
      assert stored_summary.message == "Persisted summary"
    end

    test "get_summary_context returns latest summary", %{
      session: session,
      document_id: document_id
    } do
      connect_msg = build_connect_message(document_id)
      {:ok, client_id, _} = Session.client_join(session, connect_msg)
      flush_messages()

      # Initially no summary
      {:ok, initial_context} = Session.get_summary_context(session)
      assert initial_context == nil

      # Submit a summary
      summary_handle = "context-test-summary-#{System.unique_integer([:positive])}"

      summarize_op = %{
        "clientSequenceNumber" => 1,
        "referenceSequenceNumber" => 0,
        "type" => "summarize",
        "contents" => %{
          "handle" => summary_handle,
          "message" => "Context test summary",
          "parents" => [],
          "head" => "tree-sha-abc"
        }
      }

      :ok = Session.submit_ops(session, client_id, [[summarize_op]])
      flush_messages()

      # Now should have summary context
      {:ok, context} = Session.get_summary_context(session)
      assert context != nil
      assert context.handle == summary_handle
    end
  end

  describe "storage summary operations" do
    test "store and retrieve summary by handle" do
      document_id = "storage-test-doc-#{System.unique_integer([:positive])}"
      handle = "test-handle-#{System.unique_integer([:positive])}"

      summary = %{
        handle: handle,
        sequence_number: 100,
        tree_sha: "tree123",
        commit_sha: "commit456",
        parent_handle: nil,
        message: "Test summary message"
      }

      {:ok, stored} = ETS.store_summary(@tenant_id, document_id, summary)
      assert stored.handle == handle
      assert stored.sequence_number == 100

      {:ok, retrieved} = ETS.get_summary(@tenant_id, document_id, handle)
      assert retrieved.handle == handle
      assert retrieved.sequence_number == 100
      assert retrieved.message == "Test summary message"
    end

    test "get_latest_summary returns most recent summary" do
      document_id = "latest-test-doc-#{System.unique_integer([:positive])}"

      # Store multiple summaries
      for sn <- [10, 20, 30, 15, 25] do
        summary = %{
          handle: "handle-#{sn}",
          sequence_number: sn,
          tree_sha: "tree#{sn}",
          commit_sha: nil,
          parent_handle: nil,
          message: "Summary at SN #{sn}"
        }

        {:ok, _} = ETS.store_summary(@tenant_id, document_id, summary)
      end

      {:ok, latest} = ETS.get_latest_summary(@tenant_id, document_id)
      assert latest.sequence_number == 30
      assert latest.handle == "handle-30"
    end

    test "list_summaries returns summaries in order" do
      document_id = "list-test-doc-#{System.unique_integer([:positive])}"

      # Store summaries
      for sn <- [5, 10, 15, 20] do
        summary = %{
          handle: "handle-#{sn}",
          sequence_number: sn,
          tree_sha: "tree#{sn}",
          commit_sha: nil,
          parent_handle: nil,
          message: "Summary #{sn}"
        }

        {:ok, _} = ETS.store_summary(@tenant_id, document_id, summary)
      end

      {:ok, summaries} = ETS.list_summaries(@tenant_id, document_id)
      assert length(summaries) == 4

      # Should be in ascending order by sequence number
      sns = Enum.map(summaries, & &1.sequence_number)
      assert sns == [5, 10, 15, 20]
    end

    test "get_summary returns not_found for missing handle" do
      document_id = "missing-test-doc-#{System.unique_integer([:positive])}"

      result = ETS.get_summary(@tenant_id, document_id, "nonexistent-handle")
      assert result == {:error, :not_found}
    end

    test "get_latest_summary returns not_found for document with no summaries" do
      document_id = "empty-test-doc-#{System.unique_integer([:positive])}"

      result = ETS.get_latest_summary(@tenant_id, document_id)
      assert result == {:error, :not_found}
    end
  end

  describe "summary with parent reference" do
    test "stores summary with parent handle", %{session: session, document_id: document_id} do
      connect_msg = build_connect_message(document_id)
      {:ok, client_id, _} = Session.client_join(session, connect_msg)
      flush_messages()

      # Submit first summary
      first_handle = "parent-summary-#{System.unique_integer([:positive])}"

      first_summarize = %{
        "clientSequenceNumber" => 1,
        "referenceSequenceNumber" => 0,
        "type" => "summarize",
        "contents" => %{
          "handle" => first_handle,
          "message" => "First summary",
          "parents" => [],
          "head" => "tree-first"
        }
      }

      :ok = Session.submit_ops(session, client_id, [[first_summarize]])
      flush_messages()

      # Submit second summary with parent reference
      second_handle = "child-summary-#{System.unique_integer([:positive])}"

      second_summarize = %{
        "clientSequenceNumber" => 2,
        "referenceSequenceNumber" => 0,
        "type" => "summarize",
        "contents" => %{
          "handle" => second_handle,
          "message" => "Second summary with parent",
          "parents" => [first_handle],
          "head" => "tree-second"
        }
      }

      :ok = Session.submit_ops(session, client_id, [[second_summarize]])
      flush_messages()

      # Verify second summary has parent reference
      {:ok, second_summary} = ETS.get_summary(@tenant_id, document_id, second_handle)
      assert second_summary.parent_handle == first_handle
    end
  end

  # Helper functions

  defp build_connect_message(document_id) do
    %{
      "tenantId" => @tenant_id,
      "id" => document_id,
      "client" => %{
        "user" => %{"id" => "test-user-#{System.unique_integer([:positive])}"},
        "mode" => "write",
        "details" => %{
          "capabilities" => %{"interactive" => true}
        },
        "permission" => ["doc:read", "doc:write", "summary:write"],
        "scopes" => ["doc:read", "doc:write", "summary:write"]
      },
      "mode" => "write",
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
end
