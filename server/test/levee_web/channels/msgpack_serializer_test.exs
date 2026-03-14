defmodule LeveeWeb.MsgpackSerializerTest do
  use ExUnit.Case, async: true

  alias LeveeWeb.MsgpackSerializer
  alias Phoenix.Socket.{Broadcast, Message, Reply}

  describe "encode!/1 Message" do
    test "encodes a Message as binary msgpack" do
      msg = %Message{
        join_ref: "1",
        ref: "2",
        topic: "document:tenant:doc1",
        event: "op:submit",
        payload: %{"data" => "hello"}
      }

      {:socket_push, :binary, data} = MsgpackSerializer.encode!(msg)
      decoded = Msgpax.unpack!(data)
      assert decoded == ["1", "2", "document:tenant:doc1", "op:submit", %{"data" => "hello"}]
    end

    test "handles nil join_ref and ref" do
      msg = %Message{
        join_ref: nil,
        ref: nil,
        topic: "topic",
        event: "event",
        payload: %{}
      }

      {:socket_push, :binary, data} = MsgpackSerializer.encode!(msg)
      [join_ref, ref | _rest] = Msgpax.unpack!(data)
      assert is_nil(join_ref)
      assert is_nil(ref)
    end
  end

  describe "encode!/1 Reply" do
    test "encodes a Reply with status and response" do
      reply = %Reply{
        join_ref: "1",
        ref: "2",
        topic: "document:tenant:doc1",
        status: :ok,
        payload: %{"result" => "success"}
      }

      {:socket_push, :binary, data} = MsgpackSerializer.encode!(reply)
      decoded = Msgpax.unpack!(data)

      assert decoded == [
               "1",
               "2",
               "document:tenant:doc1",
               "phx_reply",
               %{"status" => "ok", "response" => %{"result" => "success"}}
             ]
    end
  end

  describe "fastlane!/1" do
    test "encodes a Broadcast as binary msgpack" do
      broadcast = %Broadcast{
        topic: "document:tenant:doc1",
        event: "op:ack",
        payload: %{"seq" => 1}
      }

      {:socket_push, :binary, data} = MsgpackSerializer.fastlane!(broadcast)
      decoded = Msgpax.unpack!(data)
      assert decoded == [nil, nil, "document:tenant:doc1", "op:ack", %{"seq" => 1}]
    end
  end

  describe "decode!/2" do
    test "decodes a msgpack binary into a Message" do
      payload =
        Msgpax.pack!(["1", "2", "document:tenant:doc1", "op:submit", %{"data" => "hello"}])

      options = [opcode: :binary]

      msg = MsgpackSerializer.decode!(payload, options)

      assert %Message{} = msg
      assert msg.join_ref == "1"
      assert msg.ref == "2"
      assert msg.topic == "document:tenant:doc1"
      assert msg.event == "op:submit"
      assert msg.payload == %{"data" => "hello"}
    end

    test "handles nil join_ref and ref in decode" do
      payload = Msgpax.pack!([nil, nil, "topic", "event", %{}])
      msg = MsgpackSerializer.decode!(payload, opcode: :binary)

      assert msg.join_ref == nil
      assert msg.ref == nil
    end
  end

  describe "roundtrip" do
    test "Message encode then decode preserves data" do
      original = %Message{
        join_ref: "j1",
        ref: "r1",
        topic: "document:t1:d1",
        event: "op:submit",
        payload: %{"ops" => [%{"insert" => "hello"}]}
      }

      {:socket_push, :binary, encoded} = MsgpackSerializer.encode!(original)
      decoded = MsgpackSerializer.decode!(encoded, opcode: :binary)

      assert decoded.join_ref == original.join_ref
      assert decoded.ref == original.ref
      assert decoded.topic == original.topic
      assert decoded.event == original.event
      assert decoded.payload == original.payload
    end

    test "roundtrips complex nested payloads" do
      original = %Message{
        join_ref: "1",
        ref: "2",
        topic: "t",
        event: "e",
        payload: %{
          "nested" => %{"list" => [1, 2, 3], "bool" => true},
          "null_val" => nil
        }
      }

      {:socket_push, :binary, encoded} = MsgpackSerializer.encode!(original)
      decoded = MsgpackSerializer.decode!(encoded, opcode: :binary)

      assert decoded.payload == original.payload
    end
  end
end
