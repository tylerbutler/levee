defmodule LeveeWeb.MsgpackSerializer do
  @moduledoc """
  A Phoenix Socket serializer that uses MessagePack for binary WebSocket frames.

  Selected when a client connects with `vsn=3.0.0`. Messages use the same
  logical 5-element array format as the JSON serializer:

      [join_ref, ref, topic, event, payload]

  but are encoded as msgpack binary instead of JSON text.
  """

  @behaviour Phoenix.Socket.Serializer

  alias Phoenix.Socket.{Broadcast, Message, Reply}

  @impl true
  def fastlane!(%Broadcast{} = msg) do
    data = Msgpax.pack!([nil, nil, msg.topic, msg.event, msg.payload])
    {:socket_push, :binary, data}
  end

  @impl true
  def encode!(%Reply{} = reply) do
    data =
      Msgpax.pack!([
        reply.join_ref,
        reply.ref,
        reply.topic,
        "phx_reply",
        %{status: reply.status, response: reply.payload}
      ])

    {:socket_push, :binary, data}
  end

  def encode!(%Message{} = msg) do
    data =
      Msgpax.pack!([
        msg.join_ref,
        msg.ref,
        msg.topic,
        msg.event,
        msg.payload
      ])

    {:socket_push, :binary, data}
  end

  @impl true
  def decode!(raw_message, _opts) do
    [join_ref, ref, topic, event, payload | _] = Msgpax.unpack!(raw_message)

    %Message{
      topic: topic,
      event: event,
      payload: payload,
      ref: ref,
      join_ref: join_ref
    }
  end
end
