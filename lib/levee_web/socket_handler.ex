defmodule LeveeWeb.SocketHandler do
  @moduledoc """
  WebSock handler for beryl-backed WebSocket connections.

  Handles WebSocket lifecycle and message routing:
  - Registers with beryl coordinator on connect
  - Routes wire protocol messages to coordinator via runtime bridge
  - Receives {:op, msg} and {:signal, msg} from Session and pushes to client
  - Monitors Session process for disconnect cleanup
  """

  @behaviour WebSock
  # Gleam modules are loaded at runtime from BEAM files, not at Elixir compile time
  @compile {:no_warn_undefined, [:beryl@levee@runtime]}

  require Logger

  @impl WebSock
  def init(state) do
    socket_id = generate_socket_id()
    channels = state.channels

    # Create send function that sends back to this process
    me = self()

    send_fn = fn text ->
      send(me, {:send, text})
      {:ok, nil}
    end

    # Register with beryl coordinator via Gleam runtime bridge
    :beryl@levee@runtime.notify_connected(channels, socket_id, send_fn, me)

    {:ok, %{socket_id: socket_id, channels: channels, session_pid: nil}}
  end

  @impl WebSock
  def handle_in({text, [opcode: :text]}, state) do
    # Route all wire protocol messages through the Gleam runtime bridge
    :beryl@levee@runtime.handle_raw_message(state.channels, state.socket_id, text)
    {:ok, state}
  end

  def handle_in(_other, state), do: {:ok, state}

  @impl WebSock
  def handle_info({:send, text}, state) do
    {:push, {:text, text}, state}
  end

  def handle_info({:session_started, session_pid}, state) do
    # Gleam channel notifies us of the Session PID after connect_document
    _ref = Process.monitor(session_pid)
    {:ok, %{state | session_pid: session_pid}}
  end

  def handle_info({:op, op_message}, state) do
    # Session sends op messages directly to this process.
    # Split summary events (summaryAck/summaryNack) from regular ops so
    # clients process sequenced ops before the ack.
    ops = op_message["op"] || []
    doc_id = op_message["documentId"] || ""

    {summary_events, regular_ops} =
      Enum.split_with(ops, fn op -> op["type"] in ["summaryAck", "summaryNack"] end)

    op_frames =
      if regular_ops != [] do
        [{:text, encode_push(doc_id, "op", %{op_message | "op" => regular_ops})}]
      else
        []
      end

    summary_frames =
      Enum.map(summary_events, fn event ->
        {:text, encode_push(doc_id, event["type"], event)}
      end)

    case op_frames ++ summary_frames do
      [] -> {:ok, state}
      frames -> {:push, frames, state}
    end
  end

  def handle_info({:signal, signal_message}, state) do
    frame = {:text, encode_push("", "signal", signal_message)}
    {:push, frame, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{session_pid: pid} = state) do
    Logger.warning("Session process died, closing WebSocket")
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:ok, state}
  end

  def handle_info(_msg, state), do: {:ok, state}

  @impl WebSock
  def terminate(_reason, %{channels: channels, socket_id: socket_id}) do
    :beryl@levee@runtime.notify_disconnected(channels, socket_id)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp generate_socket_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  # Encode a server push as Phoenix wire protocol: [null, null, topic, event, payload]
  # Equivalent to beryl/wire.push/3 but uses Jason for Elixir map encoding
  defp encode_push(topic, event, payload) do
    Jason.encode!([nil, nil, topic, event, payload])
  end
end
