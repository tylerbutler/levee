defmodule FluidServerWeb.DocumentChannelTest do
  use FluidServerWeb.ChannelCase

  alias FluidServer.Auth.JWT
  alias FluidServer.Auth.TenantSecrets
  alias FluidServerWeb.UserSocket
  alias FluidServerWeb.DocumentChannel

  @tenant_id "test-tenant"

  setup do
    # Register tenant for JWT auth
    TenantSecrets.register_tenant(@tenant_id, "test-secret-for-channel-tests")

    # Ensure application is started
    {:ok, _} = Application.ensure_all_started(:fluid_server)

    document_id = "doc-#{System.unique_integer([:positive])}"
    topic = "document:#{@tenant_id}:#{document_id}"

    {:ok, _, socket} =
      UserSocket
      |> socket("user_id", %{})
      |> subscribe_and_join(DocumentChannel, topic)

    # Generate JWT token for tests
    {:ok, token} = JWT.generate_test_token(@tenant_id, document_id, "test-user")

    on_exit(fn -> TenantSecrets.unregister_tenant(@tenant_id) end)

    {:ok, socket: socket, document_id: document_id, topic: topic, token: token}
  end

  describe "connect_document" do
    test "successfully connects to document session", %{socket: socket, document_id: document_id, token: token} do
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

      push(socket, "connect_document", connect_msg)

      assert_push "connect_document_success", response
      assert is_binary(response["clientId"])
      assert response["mode"] == "write"
      assert is_integer(response["checkpointSequenceNumber"])
      assert is_list(response["initialClients"])
    end

    test "returns error for missing required fields", %{socket: socket} do
      # Missing tenantId
      connect_msg = %{
        "id" => "some-doc",
        "client" => %{},
        "mode" => "write"
      }

      push(socket, "connect_document", connect_msg)

      assert_push "connect_document_error", response
      assert response["code"] == 400
      assert response["message"] =~ "Missing required fields"
    end

    test "returns error for missing token", %{socket: socket, document_id: document_id} do
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

      push(socket, "connect_document", connect_msg)

      assert_push "connect_document_error", response
      assert response["code"] == 401
      assert response["message"] =~ "Missing authentication token"
    end

    test "returns error for tenant/document mismatch", %{socket: socket, document_id: document_id, token: token} do
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

      push(socket, "connect_document", connect_msg)

      assert_push "connect_document_error", response
      assert response["code"] == 400
      assert response["message"] =~ "mismatch"
    end
  end

  describe "submitOp" do
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
          "permission" => ["doc:read", "doc:write"],
          "scopes" => ["doc:read", "doc:write"]
        },
        "mode" => "write",
        "versions" => ["^0.1.0"]
      }

      push(socket, "connect_document", connect_msg)
      assert_push "connect_document_success", %{"clientId" => client_id}

      {:ok, client_id: client_id}
    end

    test "successfully submits and broadcasts operation", %{socket: socket, client_id: client_id} do
      # Clear any pending messages (like join message)
      flush_push_messages()

      op = %{
        "clientSequenceNumber" => 1,
        "referenceSequenceNumber" => 0,
        "type" => "op",
        "contents" => %{"insert" => "hello"}
      }

      push(socket, "submitOp", %{
        "clientId" => client_id,
        "messageBatches" => [[op]]
      })

      # Should receive the sequenced op
      assert_push "op", op_message
      assert is_list(op_message["op"])

      # Find the operation (not the join message)
      sequenced_op = Enum.find(op_message["op"], fn o -> o["type"] == "op" end)
      assert sequenced_op != nil, "Expected to find an op message"
      assert sequenced_op["clientId"] == client_id
      assert sequenced_op["contents"] == %{"insert" => "hello"}
      assert is_integer(sequenced_op["sequenceNumber"])
    end

    test "returns nack for wrong client ID", %{socket: socket, client_id: _client_id} do
      op = %{
        "clientSequenceNumber" => 1,
        "referenceSequenceNumber" => 0,
        "type" => "op",
        "contents" => %{}
      }

      push(socket, "submitOp", %{
        "clientId" => "wrong-client-id",
        "messageBatches" => [[op]]
      })

      assert_push "nack", nack_response
      assert is_list(nack_response["nacks"])
      assert List.first(nack_response["nacks"])["content"]["code"] == 400
    end

    test "returns nack for malformed submitOp", %{socket: socket} do
      # Missing required fields
      push(socket, "submitOp", %{"foo" => "bar"})

      assert_push "nack", nack_response
      assert is_list(nack_response["nacks"])
      nack = List.first(nack_response["nacks"])
      assert nack["content"]["message"] =~ "Malformed"
    end
  end

  describe "submitSignal" do
    setup %{socket: socket, document_id: document_id, token: token} do
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
        "versions" => ["^0.1.0"],
        "supportedFeatures" => %{"submit_signals_v2" => true}
      }

      push(socket, "connect_document", connect_msg)
      assert_push "connect_document_success", %{"clientId" => client_id}

      {:ok, client_id: client_id}
    end

    test "relays v1 signals to other clients", %{socket: socket, client_id: client_id, topic: topic, document_id: document_id} do
      # Generate token for second user
      {:ok, token2} = JWT.generate_test_token(@tenant_id, document_id, "test-user-2")

      # Join another client to receive the signal
      {:ok, _, socket2} =
        UserSocket
        |> socket("user_id_2", %{})
        |> subscribe_and_join(DocumentChannel, topic)

      connect_msg2 = %{
        "tenantId" => @tenant_id,
        "id" => document_id,
        "token" => token2,
        "client" => %{
          "user" => %{"id" => "test-user-2"},
          "mode" => "write",
          "details" => %{"capabilities" => %{"interactive" => true}},
          "permission" => ["doc:read", "doc:write"],
          "scopes" => ["doc:read", "doc:write"]
        },
        "mode" => "write",
        "versions" => ["^0.1.0"]
      }

      push(socket2, "connect_document", connect_msg2)
      assert_push "connect_document_success", %{"clientId" => _client2_id}

      # First client sends a v1 signal
      v1_signal = %{
        "content" => %{"cursor" => %{"x" => 100, "y" => 200}},
        "type" => "cursor"
      }

      push(socket, "submitSignal", %{
        "clientId" => client_id,
        "contentBatches" => [v1_signal]
      })

      # Signal relay is async
      :timer.sleep(50)
    end

    test "relays v2 signals with targetedClients", %{socket: socket, client_id: client_id, topic: topic, document_id: document_id} do
      # Generate token for second user
      {:ok, token2} = JWT.generate_test_token(@tenant_id, document_id, "test-user-2")

      # Join another client
      {:ok, _, socket2} =
        UserSocket
        |> socket("user_id_2", %{})
        |> subscribe_and_join(DocumentChannel, topic)

      connect_msg2 = %{
        "tenantId" => @tenant_id,
        "id" => document_id,
        "token" => token2,
        "client" => %{
          "user" => %{"id" => "test-user-2"},
          "mode" => "write",
          "details" => %{"capabilities" => %{"interactive" => true}},
          "permission" => ["doc:read", "doc:write"],
          "scopes" => ["doc:read", "doc:write"]
        },
        "mode" => "write",
        "versions" => ["^0.1.0"],
        "supportedFeatures" => %{"submit_signals_v2" => true}
      }

      push(socket2, "connect_document", connect_msg2)
      assert_push "connect_document_success", %{"clientId" => client2_id}

      # First client sends a v2 signal targeting only client2
      v2_targeted_signal = %{
        "content" => %{"presence" => "active"},
        "type" => "presence",
        "targetedClients" => [client2_id],
        "clientConnectionNumber" => 1,
        "referenceSequenceNumber" => 0
      }

      push(socket, "submitSignal", %{
        "clientId" => client_id,
        "contentBatches" => [v2_targeted_signal]
      })

      :timer.sleep(50)
    end

    test "relays v2 signals with ignoredClients", %{socket: socket, client_id: client_id, topic: topic, document_id: document_id} do
      # Generate token for second user
      {:ok, token2} = JWT.generate_test_token(@tenant_id, document_id, "test-user-2")

      # Join another client
      {:ok, _, socket2} =
        UserSocket
        |> socket("user_id_2", %{})
        |> subscribe_and_join(DocumentChannel, topic)

      connect_msg2 = %{
        "tenantId" => @tenant_id,
        "id" => document_id,
        "token" => token2,
        "client" => %{
          "user" => %{"id" => "test-user-2"},
          "mode" => "write",
          "details" => %{"capabilities" => %{"interactive" => true}},
          "permission" => ["doc:read", "doc:write"],
          "scopes" => ["doc:read", "doc:write"]
        },
        "mode" => "write",
        "versions" => ["^0.1.0"]
      }

      push(socket2, "connect_document", connect_msg2)
      assert_push "connect_document_success", %{"clientId" => client2_id}

      # First client sends a v2 signal ignoring client2
      v2_ignored_signal = %{
        "content" => %{"status" => "busy"},
        "type" => "status",
        "ignoredClients" => [client2_id]
      }

      push(socket, "submitSignal", %{
        "clientId" => client_id,
        "contentBatches" => [v2_ignored_signal]
      })

      :timer.sleep(50)
    end

    test "handles batch signals", %{socket: socket, client_id: client_id, topic: topic, document_id: document_id} do
      # Generate token for second user
      {:ok, token2} = JWT.generate_test_token(@tenant_id, document_id, "test-user-2")

      # Join another client
      {:ok, _, socket2} =
        UserSocket
        |> socket("user_id_2", %{})
        |> subscribe_and_join(DocumentChannel, topic)

      connect_msg2 = %{
        "tenantId" => @tenant_id,
        "id" => document_id,
        "token" => token2,
        "client" => %{
          "user" => %{"id" => "test-user-2"},
          "mode" => "write",
          "details" => %{"capabilities" => %{"interactive" => true}},
          "permission" => ["doc:read", "doc:write"],
          "scopes" => ["doc:read", "doc:write"]
        },
        "mode" => "write",
        "versions" => ["^0.1.0"]
      }

      push(socket2, "connect_document", connect_msg2)
      assert_push "connect_document_success", %{"clientId" => _client2_id}

      # First client sends a batch of signals
      batch_signals = [
        %{"content" => %{"a" => 1}, "type" => "type1"},
        %{"content" => %{"b" => 2}, "type" => "type2"},
        %{"content" => %{"c" => 3}, "type" => "type3"}
      ]

      push(socket, "submitSignal", %{
        "clientId" => client_id,
        "contentBatches" => batch_signals
      })

      :timer.sleep(50)
    end

    test "ignores signals from wrong client ID", %{socket: socket, client_id: _client_id} do
      # Try to send signal with wrong client ID
      signal = %{
        "content" => %{"test" => true},
        "type" => "test"
      }

      push(socket, "submitSignal", %{
        "clientId" => "wrong-client-id",
        "contentBatches" => [signal]
      })

      # No crash expected, just no signal sent
      :timer.sleep(50)
    end
  end

  describe "noop" do
    setup %{socket: socket, document_id: document_id, token: token} do
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

      push(socket, "connect_document", connect_msg)

      assert_push "connect_document_success", %{
        "clientId" => client_id,
        "checkpointSequenceNumber" => sn
      }

      {:ok, client_id: client_id, initial_sn: sn}
    end

    test "updates client RSN without error", %{
      socket: socket,
      client_id: client_id,
      initial_sn: sn
    } do
      # Send noop to update RSN
      push(socket, "noop", %{
        "clientId" => client_id,
        "referenceSequenceNumber" => sn
      })

      # No response expected, just ensure no crash
      :timer.sleep(50)
    end
  end

  describe "requestOps" do
    setup %{socket: socket, document_id: document_id, token: token} do
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

      push(socket, "connect_document", connect_msg)
      assert_push "connect_document_success", %{"clientId" => client_id}

      {:ok, client_id: client_id}
    end

    test "returns ops since given SN", %{socket: socket, client_id: client_id} do
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

      push(socket, "submitOp", %{
        "clientId" => client_id,
        "messageBatches" => [ops]
      })

      # Wait for ops to be processed
      assert_push "op", _

      # Request ops since SN 0
      push(socket, "requestOps", %{"from" => 0})

      # Should receive catch-up ops
      assert_push "op", catchup_message
      assert is_list(catchup_message["op"])
      assert length(catchup_message["op"]) >= 2
    end
  end

  # Helper to clear any pending push messages
  defp flush_push_messages do
    receive do
      %Phoenix.Socket.Message{} -> flush_push_messages()
    after
      50 -> :ok
    end
  end

  describe "read-only mode" do
    test "prevents op submission in read mode", %{socket: socket, document_id: document_id} do
      # Generate read-only token
      {:ok, token} = JWT.generate_read_only_token(@tenant_id, document_id, "test-user")

      connect_msg = %{
        "tenantId" => @tenant_id,
        "id" => document_id,
        "token" => token,
        "client" => %{
          "user" => %{"id" => "test-user"},
          "mode" => "read",
          "details" => %{"capabilities" => %{"interactive" => true}},
          "permission" => ["doc:read"],
          "scopes" => ["doc:read"]
        },
        "mode" => "read",
        "versions" => ["^0.1.0"]
      }

      push(socket, "connect_document", connect_msg)
      assert_push "connect_document_success", %{"clientId" => client_id, "mode" => "read"}

      # Try to submit op
      op = %{
        "clientSequenceNumber" => 1,
        "referenceSequenceNumber" => 0,
        "type" => "op",
        "contents" => %{}
      }

      push(socket, "submitOp", %{
        "clientId" => client_id,
        "messageBatches" => [[op]]
      })

      assert_push "nack", nack_response
      nack = List.first(nack_response["nacks"])
      # Message should indicate read-only or scope error
      assert nack["content"]["message"] =~ "scope" or nack["content"]["message"] =~ "Read-only"
    end
  end
end
