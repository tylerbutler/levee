defmodule LeveeWeb.DocumentChannelTest do
  use LeveeWeb.WebSocketCase

  alias Levee.Auth.JWT
  alias Levee.Auth.TenantSecrets

  @tenant_id "test-tenant"

  setup do
    # Register tenant for JWT auth
    TenantSecrets.register_tenant(@tenant_id, "test-secret-for-channel-tests")

    # Ensure application is started
    {:ok, _} = Application.ensure_all_started(:levee)

    document_id = "doc-#{System.unique_integer([:positive])}"
    topic = "document:#{@tenant_id}:#{document_id}"

    # Connect WebSocket and join topic
    ws = ws_connect()
    join_ref = ws_join(ws, topic)

    # Generate JWT token for tests
    {:ok, token} = JWT.generate_test_token(@tenant_id, document_id, "test-user")

    on_exit(fn -> TenantSecrets.unregister_tenant(@tenant_id) end)

    {:ok, ws: ws, join_ref: join_ref, document_id: document_id, topic: topic, token: token}
  end

  # Helper: send connect_document and assert success
  defp do_connect_document(ws, join_ref, topic, tenant_id, document_id, token, opts \\ []) do
    mode = Keyword.get(opts, :mode, "write")
    user_id = Keyword.get(opts, :user_id, "test-user")
    scopes = Keyword.get(opts, :scopes, ["doc:read", "doc:write"])
    features = Keyword.get(opts, :features, nil)

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

    connect_msg =
      if features, do: Map.put(connect_msg, "supportedFeatures", features), else: connect_msg

    ref = make_ref_string()
    ws_push(ws, join_ref, ref, topic, "connect_document", connect_msg)
    assert_ws_push("connect_document_success")
  end

  describe "connect_document" do
    test "successfully connects to document session", %{
      ws: ws,
      join_ref: join_ref,
      topic: topic,
      document_id: document_id,
      token: token
    } do
      connect_msg = %{
        "tenantId" => @tenant_id,
        "id" => document_id,
        "token" => token,
        "client" => %{
          "user" => %{"id" => "test-user"},
          "mode" => "write",
          "details" => %{"capabilities" => %{"interactive" => true}},
          "permission" => ["doc:read", "doc:write"],
          "scopes" => ["doc:read", "doc:write"]
        },
        "mode" => "write",
        "versions" => ["^0.1.0"]
      }

      ref = make_ref_string()
      ws_push(ws, join_ref, ref, topic, "connect_document", connect_msg)

      response = assert_ws_push("connect_document_success")
      assert is_binary(response["clientId"])
      assert response["mode"] == "write"
      assert is_integer(response["checkpointSequenceNumber"])
      assert is_list(response["initialClients"])
    end

    test "returns error for missing required fields", %{
      ws: ws,
      join_ref: join_ref,
      topic: topic
    } do
      # Missing tenantId and token
      connect_msg = %{
        "id" => "some-doc",
        "client" => %{},
        "mode" => "write"
      }

      ref = make_ref_string()
      ws_push(ws, join_ref, ref, topic, "connect_document", connect_msg)

      response = assert_ws_push("connect_document_error")
      assert response["code"] == 400
      assert response["message"] =~ "Missing required fields"
    end

    test "returns error for missing token", %{
      ws: ws,
      join_ref: join_ref,
      topic: topic,
      document_id: document_id
    } do
      connect_msg = %{
        "tenantId" => @tenant_id,
        "id" => document_id,
        "client" => %{
          "user" => %{"id" => "test-user"},
          "mode" => "write"
        },
        "mode" => "write",
        "versions" => []
      }

      ref = make_ref_string()
      ws_push(ws, join_ref, ref, topic, "connect_document", connect_msg)

      response = assert_ws_push("connect_document_error")
      assert response["code"] == 400
      assert response["message"] =~ "Missing required fields"
    end

    test "returns error for tenant/document mismatch", %{
      ws: ws,
      join_ref: join_ref,
      topic: topic,
      document_id: document_id,
      token: token
    } do
      connect_msg = %{
        "tenantId" => "wrong-tenant",
        "id" => document_id,
        "token" => token,
        "client" => %{
          "user" => %{"id" => "test-user"},
          "mode" => "write"
        },
        "mode" => "write",
        "versions" => []
      }

      ref = make_ref_string()
      ws_push(ws, join_ref, ref, topic, "connect_document", connect_msg)

      response = assert_ws_push("connect_document_error")
      assert response["code"] == 400
      assert response["message"] =~ "mismatch"
    end
  end

  describe "submitOp" do
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

    test "successfully submits and broadcasts operation", %{
      ws: ws,
      join_ref: join_ref,
      topic: topic,
      client_id: client_id
    } do
      # Clear any pending messages (like join op)
      flush_ws_messages()

      op = %{
        "clientSequenceNumber" => 1,
        "referenceSequenceNumber" => 0,
        "type" => "op",
        "contents" => %{"insert" => "hello"}
      }

      ref = make_ref_string()

      ws_push(ws, join_ref, ref, topic, "submitOp", %{
        "clientId" => client_id,
        "messageBatches" => [[op]]
      })

      # Should receive the sequenced op
      op_message = assert_ws_push("op")
      assert is_list(op_message["op"])

      # Find the operation (not the join message)
      sequenced_op = Enum.find(op_message["op"], fn o -> o["type"] == "op" end)
      assert sequenced_op != nil, "Expected to find an op message"
      assert sequenced_op["clientId"] == client_id
      assert sequenced_op["contents"] == %{"insert" => "hello"}
      assert is_integer(sequenced_op["sequenceNumber"])
    end

    test "returns nack for wrong client ID", %{
      ws: ws,
      join_ref: join_ref,
      topic: topic,
      client_id: _client_id
    } do
      op = %{
        "clientSequenceNumber" => 1,
        "referenceSequenceNumber" => 0,
        "type" => "op",
        "contents" => %{}
      }

      ref = make_ref_string()

      ws_push(ws, join_ref, ref, topic, "submitOp", %{
        "clientId" => "wrong-client-id",
        "messageBatches" => [[op]]
      })

      nack_response = assert_ws_push("nack")
      assert is_list(nack_response["nacks"])
      assert List.first(nack_response["nacks"])["content"]["code"] == 400
    end

    test "returns nack for malformed submitOp", %{
      ws: ws,
      join_ref: join_ref,
      topic: topic
    } do
      # Missing required fields
      ref = make_ref_string()
      ws_push(ws, join_ref, ref, topic, "submitOp", %{"foo" => "bar"})

      nack_response = assert_ws_push("nack")
      assert is_list(nack_response["nacks"])
      nack = List.first(nack_response["nacks"])
      assert nack["content"]["message"] =~ "Malformed"
    end
  end

  describe "submitSignal" do
    setup %{
      ws: ws,
      join_ref: join_ref,
      topic: topic,
      document_id: document_id,
      token: token
    } do
      response =
        do_connect_document(ws, join_ref, topic, @tenant_id, document_id, token,
          features: %{"submit_signals_v2" => true}
        )

      {:ok, client_id: response["clientId"]}
    end

    test "relays v1 signals to other clients", %{
      ws: ws,
      join_ref: join_ref,
      topic: topic,
      client_id: client_id,
      document_id: document_id
    } do
      # Generate token for second user
      {:ok, token2} = JWT.generate_test_token(@tenant_id, document_id, "test-user-2")

      # Join another client to receive the signal
      ws2 = ws_connect()
      join_ref2 = ws_join(ws2, topic)

      do_connect_document(ws2, join_ref2, topic, @tenant_id, document_id, token2,
        user_id: "test-user-2"
      )

      # First client sends a v1 signal
      v1_signal = %{
        "content" => %{"cursor" => %{"x" => 100, "y" => 200}},
        "type" => "cursor"
      }

      ref = make_ref_string()

      ws_push(ws, join_ref, ref, topic, "submitSignal", %{
        "clientId" => client_id,
        "contentBatches" => [v1_signal]
      })

      # Signal relay is async
      :timer.sleep(50)
    end

    test "relays v2 signals with targetedClients", %{
      ws: ws,
      join_ref: join_ref,
      topic: topic,
      client_id: client_id,
      document_id: document_id
    } do
      # Generate token for second user
      {:ok, token2} = JWT.generate_test_token(@tenant_id, document_id, "test-user-2")

      # Join another client
      ws2 = ws_connect()
      join_ref2 = ws_join(ws2, topic)

      response2 =
        do_connect_document(ws2, join_ref2, topic, @tenant_id, document_id, token2,
          user_id: "test-user-2",
          features: %{"submit_signals_v2" => true}
        )

      client2_id = response2["clientId"]

      # First client sends a v2 signal targeting only client2
      v2_targeted_signal = %{
        "content" => %{"presence" => "active"},
        "type" => "presence",
        "targetedClients" => [client2_id],
        "clientConnectionNumber" => 1,
        "referenceSequenceNumber" => 0
      }

      ref = make_ref_string()

      ws_push(ws, join_ref, ref, topic, "submitSignal", %{
        "clientId" => client_id,
        "contentBatches" => [v2_targeted_signal]
      })

      :timer.sleep(50)
    end

    test "relays v2 signals with ignoredClients", %{
      ws: ws,
      join_ref: join_ref,
      topic: topic,
      client_id: client_id,
      document_id: document_id
    } do
      # Generate token for second user
      {:ok, token2} = JWT.generate_test_token(@tenant_id, document_id, "test-user-2")

      # Join another client
      ws2 = ws_connect()
      join_ref2 = ws_join(ws2, topic)

      response2 =
        do_connect_document(ws2, join_ref2, topic, @tenant_id, document_id, token2,
          user_id: "test-user-2"
        )

      client2_id = response2["clientId"]

      # First client sends a v2 signal ignoring client2
      v2_ignored_signal = %{
        "content" => %{"status" => "busy"},
        "type" => "status",
        "ignoredClients" => [client2_id]
      }

      ref = make_ref_string()

      ws_push(ws, join_ref, ref, topic, "submitSignal", %{
        "clientId" => client_id,
        "contentBatches" => [v2_ignored_signal]
      })

      :timer.sleep(50)
    end

    test "handles batch signals", %{
      ws: ws,
      join_ref: join_ref,
      topic: topic,
      client_id: client_id,
      document_id: document_id
    } do
      # Generate token for second user
      {:ok, token2} = JWT.generate_test_token(@tenant_id, document_id, "test-user-2")

      # Join another client
      ws2 = ws_connect()
      join_ref2 = ws_join(ws2, topic)

      do_connect_document(ws2, join_ref2, topic, @tenant_id, document_id, token2,
        user_id: "test-user-2"
      )

      # First client sends a batch of signals
      batch_signals = [
        %{"content" => %{"a" => 1}, "type" => "type1"},
        %{"content" => %{"b" => 2}, "type" => "type2"},
        %{"content" => %{"c" => 3}, "type" => "type3"}
      ]

      ref = make_ref_string()

      ws_push(ws, join_ref, ref, topic, "submitSignal", %{
        "clientId" => client_id,
        "contentBatches" => batch_signals
      })

      :timer.sleep(50)
    end

    test "ignores signals from wrong client ID", %{
      ws: ws,
      join_ref: join_ref,
      topic: topic,
      client_id: _client_id
    } do
      # Try to send signal with wrong client ID
      signal = %{
        "content" => %{"test" => true},
        "type" => "test"
      }

      ref = make_ref_string()

      ws_push(ws, join_ref, ref, topic, "submitSignal", %{
        "clientId" => "wrong-client-id",
        "contentBatches" => [signal]
      })

      # No crash expected, just no signal sent
      :timer.sleep(50)
    end
  end

  describe "noop" do
    setup %{
      ws: ws,
      join_ref: join_ref,
      topic: topic,
      document_id: document_id,
      token: token
    } do
      response = do_connect_document(ws, join_ref, topic, @tenant_id, document_id, token)

      {:ok, client_id: response["clientId"], initial_sn: response["checkpointSequenceNumber"]}
    end

    test "updates client RSN without error", %{
      ws: ws,
      join_ref: join_ref,
      topic: topic,
      client_id: client_id,
      initial_sn: sn
    } do
      # Send noop to update RSN
      ref = make_ref_string()

      ws_push(ws, join_ref, ref, topic, "noop", %{
        "clientId" => client_id,
        "referenceSequenceNumber" => sn
      })

      # No response expected, just ensure no crash
      :timer.sleep(50)
    end
  end

  describe "requestOps" do
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

    test "returns ops since given SN", %{
      ws: ws,
      join_ref: join_ref,
      topic: topic,
      client_id: client_id
    } do
      # Submit some ops first
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
        }
      ]

      ref = make_ref_string()

      ws_push(ws, join_ref, ref, topic, "submitOp", %{
        "clientId" => client_id,
        "messageBatches" => [ops]
      })

      # Wait for ops to be processed
      assert_ws_push("op")

      # Request ops since SN 0
      ref2 = make_ref_string()
      ws_push(ws, join_ref, ref2, topic, "requestOps", %{"from" => 0})

      # Should receive catch-up ops
      catchup_message = assert_ws_push("op")
      assert is_list(catchup_message["op"])
      assert length(catchup_message["op"]) >= 2
    end
  end

  describe "read-only mode" do
    test "prevents op submission in read mode", %{
      ws: ws,
      join_ref: join_ref,
      topic: topic,
      document_id: document_id
    } do
      # Generate read-only token
      {:ok, read_token} = JWT.generate_read_only_token(@tenant_id, document_id, "test-user")

      response =
        do_connect_document(ws, join_ref, topic, @tenant_id, document_id, read_token,
          mode: "read",
          scopes: ["doc:read"]
        )

      assert response["mode"] == "read"
      client_id = response["clientId"]

      # Try to submit op
      op = %{
        "clientSequenceNumber" => 1,
        "referenceSequenceNumber" => 0,
        "type" => "op",
        "contents" => %{}
      }

      ref = make_ref_string()

      ws_push(ws, join_ref, ref, topic, "submitOp", %{
        "clientId" => client_id,
        "messageBatches" => [[op]]
      })

      nack_response = assert_ws_push("nack")
      nack = List.first(nack_response["nacks"])
      # Message should indicate read-only or scope error
      assert nack["content"]["message"] =~ "scope" or nack["content"]["message"] =~ "Read-only"
    end
  end
end
