defmodule LeveeWeb.WebSocketCase do
  @moduledoc """
  Test case for WebSocket tests using raw wire protocol.

  Provides helpers for connecting, sending, and receiving
  Phoenix wire protocol messages via WebSockex.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import LeveeWeb.WebSocketCase
    end
  end

  setup _tags do
    {:ok, _} = Application.ensure_all_started(:levee)
    :ok
  end

  @doc "Connect to the WebSocket endpoint"
  def ws_connect do
    url = "ws://127.0.0.1:#{port()}/socket/websocket"
    {:ok, pid} = WsClient.start_link(url, self())
    pid
  end

  @doc "Send a wire protocol message"
  def ws_push(ws, join_ref, ref, topic, event, payload) do
    msg = Jason.encode!([join_ref, ref, topic, event, payload])
    WsClient.send_text(ws, msg)
  end

  @doc "Join a topic and assert success"
  def ws_join(ws, topic) do
    join_ref = make_ref_string()
    ref = make_ref_string()
    ws_push(ws, join_ref, ref, topic, "phx_join", %{})
    assert_ws_reply(ref, "ok")
    join_ref
  end

  @doc "Receive the next wire protocol message matching an event"
  def assert_ws_push(event, timeout \\ 1000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    receive_matching(event, deadline)
  end

  @doc "Assert a wire protocol reply is received for a given ref"
  def assert_ws_reply(ref_val, status, timeout \\ 1000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    receive_reply(ref_val, status, deadline)
  end

  @doc "Drain any pending WebSocket messages"
  def flush_ws_messages(timeout \\ 50) do
    receive do
      {:ws_message, _} -> flush_ws_messages(timeout)
    after
      timeout -> :ok
    end
  end

  @doc "Generate a unique ref string"
  def make_ref_string do
    System.unique_integer([:positive]) |> Integer.to_string()
  end

  defp port do
    Application.get_env(:levee, LeveeWeb.Endpoint)[:http][:port] || 4002
  end

  # Receive a push message matching the event, discarding non-matching ones
  defp receive_matching(event, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:ws_message, text} ->
        case Jason.decode!(text) do
          [_jr, _ref, _topic, ^event, payload] ->
            payload

          [_jr, ref, _topic, "phx_reply", %{"status" => _} = payload]
          when event == "phx_reply" ->
            %{ref: ref, payload: payload}

          _other ->
            # Not the event we want, try again
            receive_matching(event, deadline)
        end
    after
      remaining ->
        ExUnit.Assertions.flunk("Expected to receive #{event} within timeout")
    end
  end

  # Receive a reply for a specific ref
  defp receive_reply(ref_val, status, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:ws_message, text} ->
        case Jason.decode!(text) do
          [_jr, ^ref_val, _topic, "phx_reply", %{"status" => ^status} = payload] ->
            payload["response"]

          _other ->
            # Not the reply we want, try again
            receive_reply(ref_val, status, deadline)
        end
    after
      remaining ->
        ExUnit.Assertions.flunk(
          "Expected reply for ref #{ref_val} with status #{status} within timeout"
        )
    end
  end
end
