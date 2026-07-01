defmodule LeveeWeb.SocketIOWebSockTest do
  @moduledoc """
  Exercises `LeveeWeb.SocketIOWebSock`'s `WebSock` callbacks directly (no
  live socket needed — `init/1`, `handle_in/2`, `handle_info/2` are plain
  functions), covering both the Engine.IO/Socket.IO transport framing it
  delegates to `Levee.Sluice` and the `connect_document` auth/session flow
  it still owns against the real `Levee.Documents` runtime.
  """

  use ExUnit.Case, async: false

  alias Levee.Auth.JWT
  alias Levee.Auth.TenantSecrets
  alias LeveeWeb.SocketIOWebSock

  @tenant_id "socketio-websock-test-tenant"

  setup do
    TenantSecrets.register_tenant(@tenant_id, "socketio-websock-test-secret")
    {:ok, _} = Application.ensure_all_started(:levee)

    document_id = "doc-#{System.unique_integer([:positive])}"

    on_exit(fn -> TenantSecrets.unregister_tenant(@tenant_id) end)

    {:ok, document_id: document_id}
  end

  test "init/1 pushes an Engine.IO open packet with a sid" do
    assert {:push, {:text, packet}, state} = SocketIOWebSock.init(%{})

    assert "0" <> json = packet
    assert {:ok, %{"sid" => sid}} = Jason.decode(json)
    assert is_binary(sid)
    assert state.sid == sid
    assert state.client_id == nil
    assert state.session_pid == nil
  end

  test "handle_in/2 replies to an Engine.IO ping with a pong" do
    {:push, {:text, _open}, state} = SocketIOWebSock.init(%{})

    assert {:push, {:text, "3"}, ^state} =
             SocketIOWebSock.handle_in({"2", [opcode: :text]}, state)
  end

  test "handle_in/2 acknowledges Engine.IO pong with no reply" do
    {:push, {:text, _open}, state} = SocketIOWebSock.init(%{})

    assert {:ok, ^state} = SocketIOWebSock.handle_in({"3", [opcode: :text]}, state)
  end

  test "handle_in/2 acks the Socket.IO namespace connect with the session sid" do
    {:push, {:text, _open}, state} = SocketIOWebSock.init(%{})

    assert {:push, {:text, ack}, ^state} =
             SocketIOWebSock.handle_in({"40", [opcode: :text]}, state)

    assert ack == "40{\"sid\":\"#{state.sid}\"}"
  end

  test "handle_in/2 ignores unrecognized frames" do
    {:push, {:text, _open}, state} = SocketIOWebSock.init(%{})

    assert {:ok, ^state} = SocketIOWebSock.handle_in({"garbage", [opcode: :text]}, state)
  end

  test "handle_info/2 pushes op(documentId, messages)", %{document_id: document_id} do
    {:push, {:text, _open}, state} = SocketIOWebSock.init(%{})

    op_message = %{"documentId" => document_id, "op" => [%{"sequenceNumber" => 1}]}

    assert {:push, {:text, frame}, ^state} =
             SocketIOWebSock.handle_info({:op, op_message}, state)

    assert frame == ~s(42["op","#{document_id}",[{"sequenceNumber":1}]])
  end

  test "handle_info/2 pushes signal(signalMessage)" do
    {:push, {:text, _open}, state} = SocketIOWebSock.init(%{})

    assert {:push, {:text, frame}, ^state} =
             SocketIOWebSock.handle_info({:signal, %{"clientId" => "c1"}}, state)

    assert frame == ~s(42["signal",{"clientId":"c1"}])
  end

  test "connect_document success pushes connect_document_success with claims", %{
    document_id: document_id
  } do
    {:push, {:text, _open}, state} = SocketIOWebSock.init(%{})
    {:ok, token} = JWT.generate_test_token(@tenant_id, document_id, "test-user")

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

    frame = ~s(42["connect_document",#{Jason.encode!(connect_msg)}])

    assert {:push, {:text, reply}, new_state} =
             SocketIOWebSock.handle_in({frame, [opcode: :text]}, state)

    assert "42" <> json = reply
    assert {:ok, ["connect_document_success", response]} = Jason.decode(json)
    assert response["clientId"] == new_state.client_id
    assert response["claims"]["documentId"] == document_id
    assert response["claims"]["tenantId"] == @tenant_id
    assert is_pid(new_state.session_pid)
  end

  test "connect_document rejects an unauthorized (unknown tenant) token", %{
    document_id: document_id
  } do
    {:push, {:text, _open}, state} = SocketIOWebSock.init(%{})
    {:ok, token} = JWT.generate_test_token(@tenant_id, document_id, "test-user")

    connect_msg = %{"tenantId" => "wrong-tenant", "id" => document_id, "token" => token}
    frame = ~s(42["connect_document",#{Jason.encode!(connect_msg)}])

    assert {:push, {:text, reply}, ^state} =
             SocketIOWebSock.handle_in({frame, [opcode: :text]}, state)

    assert "42" <> json = reply
    assert {:ok, ["connect_document_error", %{"code" => 400}]} = Jason.decode(json)
  end

  test "connect_document rejects write mode without a doc:write scope", %{
    document_id: document_id
  } do
    {:push, {:text, _open}, state} = SocketIOWebSock.init(%{})

    {:ok, token} =
      JWT.generate_test_token(@tenant_id, document_id, "test-user", scopes: ["doc:read"])

    connect_msg = %{
      "tenantId" => @tenant_id,
      "id" => document_id,
      "token" => token,
      "mode" => "write"
    }

    frame = ~s(42["connect_document",#{Jason.encode!(connect_msg)}])

    assert {:push, {:text, reply}, ^state} =
             SocketIOWebSock.handle_in({frame, [opcode: :text]}, state)

    assert "42" <> json = reply
    assert {:ok, ["connect_document_error", %{"message" => message}]} = Jason.decode(json)
    assert message =~ "write_mode_without_write_scope"
  end
end
