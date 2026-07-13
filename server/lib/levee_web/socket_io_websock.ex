defmodule LeveeWeb.SocketIOWebSock do
  @moduledoc """
  Engine.IO/Socket.IO WebSock adapter for Fluid Routerlicious compatibility.

  This Levee-owned compatibility transport terminates the
  WebSocket connection and drives Levee's own JWT verification and document
  Session/Registry runtime, but delegates the Engine.IO/Socket.IO framing and
  `connect_document` payload/scope decisions to Floodgate (`Levee.Floodgate`,
  backed by the Gleam `floodgate/socketio` and `floodgate/connect_document`
  modules, which build on `windsock`/`dewdrop`/`spillway`). Protocol-neutral
  behavior can remain shared through `Levee.Floodgate`, while Levee keeps its
  own Session/Registry runtime. Per ADR-004, Levee and standalone Floodgate
  coexist; this endpoint is not coupled to replacing the Phoenix Channels
  stack.
  """

  @behaviour WebSock

  alias Levee.Auth.JWT
  alias Levee.Documents.Session
  alias Levee.Floodgate

  require Logger

  @impl true
  def init(_state) do
    sid = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

    open_packet = Floodgate.encode_open(sid, 25_000, 20_000, 1_000_000)

    {:push, {:text, open_packet}, %{sid: sid, client_id: nil, session_pid: nil}}
  end

  @impl true
  def handle_in({frame, [opcode: :text]}, state) do
    case Floodgate.classify_frame(frame) do
      :engine_ping ->
        {:push, {:text, Floodgate.encode_pong()}, state}

      :engine_pong ->
        {:ok, state}

      :socket_connect ->
        {:push, {:text, Floodgate.encode_connect_ack(state.sid)}, state}

      {:fluid_event, "connect_document", [payload | _]} when is_map(payload) ->
        connect_document(payload, state)

      {:fluid_event, event, _args} ->
        Logger.debug("Unhandled Socket.IO Fluid event: #{inspect(event)}")
        {:ok, state}

      {:unrecognized, reason} ->
        Logger.debug("Unhandled Socket.IO frame: #{inspect(frame)}, reason: #{inspect(reason)}")
        {:ok, state}
    end
  end

  @impl true
  def handle_info({:op, op_message}, state) do
    document_id = op_message["documentId"]
    messages = op_message["op"] || []

    {:push, {:text, Floodgate.encode_op(document_id, messages)}, state}
  end

  def handle_info({:signal, signal_message}, state) do
    {:push, {:text, Floodgate.encode_signal(signal_message)}, state}
  end

  def handle_info(_message, state), do: {:ok, state}

  @impl true
  def terminate(_reason, %{session_pid: session_pid, client_id: client_id})
      when is_pid(session_pid) and is_binary(client_id) do
    Session.client_leave(session_pid, client_id)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp connect_document(payload, state) do
    with {:ok, {tenant_id, document_id, token}} <- Floodgate.parse_connect_request(payload),
         {:ok, claims} <- verify_token(token, tenant_id, document_id),
         :ok <- validate_mode(payload, claims),
         {:ok, session_pid} <-
           Levee.Documents.Registry.get_or_create_session(tenant_id, document_id),
         {:ok, client_id, connected_response} <- Session.client_join(session_pid, payload) do
      response =
        Map.put(connected_response, "claims", %{
          "documentId" => claims.documentId,
          "scopes" => claims.scopes,
          "tenantId" => claims.tenantId,
          "user" => %{"id" => claims.user.id},
          "iat" => claims.iat,
          "exp" => claims.exp,
          "ver" => claims.ver
        })

      {:push, {:text, Floodgate.encode_connect_document_success(response)},
       %{state | client_id: client_id, session_pid: session_pid}}
    else
      {:error, reason} ->
        {:push,
         {:text,
          Floodgate.encode_connect_document_error(%{"code" => 400, "message" => inspect(reason)})},
         state}
    end
  end

  defp verify_token(token, tenant_id, document_id) do
    with {:ok, claims} <- JWT.verify(token, tenant_id),
         false <- JWT.expired?(claims),
         true <- claims.tenantId == tenant_id,
         true <- claims.documentId == document_id,
         true <- JWT.has_scope?(claims, Floodgate.read_scope()) do
      {:ok, claims}
    else
      true -> {:error, :token_expired}
      false -> {:error, :invalid_claims}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_mode(payload, claims) do
    Floodgate.validate_mode_scope(payload, claims.scopes)
  end
end
