defmodule LeveeWeb.SocketIOWebSock do
  @moduledoc """
  Small Engine.IO/Socket.IO server shim for Fluid Routerlicious compatibility.

  It implements only the websocket transport pieces needed to establish a Fluid
  delta stream: Engine.IO open, Socket.IO namespace connect, heartbeat, and the
  `connect_document` Fluid event.
  """

  @behaviour WebSock

  alias Levee.Auth.JWT
  alias Levee.Documents.Session

  require Logger

  @engine_open "0"
  @engine_ping "2"
  @engine_pong "3"
  @socket_connect "40"

  @impl true
  def init(_state) do
    sid = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

    open_packet =
      @engine_open <>
        Jason.encode!(%{
          "sid" => sid,
          "upgrades" => [],
          "pingInterval" => 25_000,
          "pingTimeout" => 20_000,
          "maxPayload" => 1_000_000
        })

    {:push, {:text, open_packet}, %{sid: sid, client_id: nil, session_pid: nil}}
  end

  @impl true
  def handle_in({@engine_ping, [opcode: :text]}, state) do
    {:push, {:text, @engine_pong}, state}
  end

  def handle_in({@engine_pong, [opcode: :text]}, state) do
    {:ok, state}
  end

  def handle_in({@socket_connect, [opcode: :text]}, state) do
    {:push, {:text, @socket_connect <> Jason.encode!(%{"sid" => state.sid})}, state}
  end

  def handle_in({frame, [opcode: :text]}, state) do
    case decode_fluid_event(frame) do
      {:ok, {"connect_document", [payload | _]}} when is_map(payload) ->
        connect_document(payload, state)

      {:ok, {event, _args}} ->
        Logger.debug("Unhandled Socket.IO Fluid event: #{inspect(event)}")
        {:ok, state}

      {:error, reason} ->
        Logger.debug("Unhandled Socket.IO frame: #{inspect(frame)}, reason: #{inspect(reason)}")
        {:ok, state}
    end
  end

  @impl true
  def handle_info({:op, op_message}, state) do
    document_id = op_message["documentId"]
    messages = op_message["op"] || []

    push_event("op", [document_id, messages], state)
  end

  def handle_info({:signal, signal_message}, state) do
    push_event("signal", [signal_message], state)
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
    with {:ok, tenant_id} <- fetch_string(payload, "tenantId"),
         {:ok, document_id} <- fetch_string(payload, "id"),
         {:ok, token} <- fetch_string(payload, "token"),
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

      push_event("connect_document_success", [response], %{
        state
        | client_id: client_id,
          session_pid: session_pid
      })
    else
      {:error, reason} ->
        push_event(
          "connect_document_error",
          [%{"code" => 400, "message" => inspect(reason)}],
          state
        )
    end
  end

  defp push_event(event, args, state) do
    {:push, {:text, encode_fluid_event(event, args)}, state}
  end

  defp decode_fluid_event(frame) do
    case apply(:dewdrop, :decode, [frame]) do
      {:ok, {:incoming, event, args}} -> {:ok, {event, args}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp encode_fluid_event(event, args) do
    apply(:windsock, :encode, [event, Enum.map(args, &to_gleam_json/1)])
  end

  defp to_gleam_json(value) when is_binary(value), do: gleam_json(:string, [value])
  defp to_gleam_json(value) when is_boolean(value), do: gleam_json(:bool, [value])
  defp to_gleam_json(value) when is_integer(value), do: gleam_json(:int, [value])
  defp to_gleam_json(value) when is_float(value), do: gleam_json(:float, [value])
  defp to_gleam_json(nil), do: gleam_json(:null, [])

  defp to_gleam_json(values) when is_list(values) do
    gleam_json(:preprocessed_array, [Enum.map(values, &to_gleam_json/1)])
  end

  defp to_gleam_json(value) when is_map(value) do
    value
    |> Enum.map(fn {key, map_value} -> {to_string(key), to_gleam_json(map_value)} end)
    |> then(&gleam_json(:object, [&1]))
  end

  defp gleam_json(function, args), do: apply(:gleam@json, function, args)

  defp fetch_string(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_field, key}}
    end
  end

  defp verify_token(token, tenant_id, document_id) do
    with {:ok, claims} <- JWT.verify(token, tenant_id),
         false <- JWT.expired?(claims),
         true <- claims.tenantId == tenant_id,
         true <- claims.documentId == document_id,
         true <- JWT.has_scope?(claims, spillway_scope(:doc_read)) do
      {:ok, claims}
    else
      true -> {:error, :token_expired}
      false -> {:error, :invalid_claims}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_mode(%{"mode" => "write"}, claims) do
    if JWT.has_scope?(claims, spillway_scope(:doc_write)),
      do: :ok,
      else: {:error, :write_mode_without_write_scope}
  end

  defp validate_mode(_payload, _claims), do: :ok

  defp spillway_scope(scope), do: apply(:spillway@types, :scope_to_string, [scope])
end
