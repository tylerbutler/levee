defmodule LeveeWeb.DocumentChannel do
  @moduledoc """
  Phoenix Channel for Fluid Framework document collaboration.

  Handles the WebSocket protocol events:
  - connect_document: Client joins a document session
  - submitOp: Client submits operations
  - submitSignal: Client sends signals
  - Delta catch-up on reconnection

  ## Authentication

  Clients must provide a valid JWT token in the connect_document message.
  The token is validated against:
  - Signature (using tenant secret)
  - Expiration
  - Tenant match
  - Document match
  - Required scopes (doc:read for connection, doc:write for operations)
  """

  use Phoenix.Channel

  alias Levee.Auth.JWT
  alias Levee.Documents.Session

  require Logger

  # Maximum ops per batch submission
  @max_batch_size 100

  @impl true
  def join("document:" <> topic, _params, socket) do
    # Parse tenant_id:document_id from topic
    case String.split(topic, ":", parts: 2) do
      [tenant_id, document_id] ->
        socket =
          socket
          |> assign(:tenant_id, tenant_id)
          |> assign(:document_id, document_id)
          |> assign(:client_id, nil)
          |> assign(:mode, nil)
          |> assign(:connected, false)

        {:ok, socket}

      _ ->
        {:error, %{reason: "invalid_topic"}}
    end
  end

  @impl true
  def handle_in("connect_document", payload, socket) do
    with {:ok, connect_msg} <- parse_connect_message(payload),
         :ok <- validate_tenant_document(connect_msg, socket),
         {:ok, claims} <- validate_token(connect_msg, socket),
         :ok <- validate_connection_mode(connect_msg, claims),
         {:ok, session_pid} <- get_or_create_session(socket),
         {:ok, client_id, connected_response} <- Session.client_join(session_pid, connect_msg) do
      # Check if this is a reconnection with a last seen SN
      last_seen_sn = connect_msg["lastSeenSequenceNumber"]

      # Update connected_response with actual validated claims
      connected_response =
        Map.put(connected_response, "claims", format_claims_for_response(claims))

      # Update socket with client info and claims
      socket =
        socket
        |> assign(:client_id, client_id)
        |> assign(:mode, connect_msg["mode"] || "write")
        |> assign(:connected, true)
        |> assign(:session_pid, session_pid)
        |> assign(:last_seen_sn, last_seen_sn)
        |> assign(:claims, claims)

      # Monitor the session process
      Process.monitor(session_pid)

      push(socket, "connect_document_success", connected_response)

      # If reconnecting, send delta catch-up
      if last_seen_sn && is_integer(last_seen_sn) do
        send(self(), {:send_delta_catchup, last_seen_sn})
      end

      {:noreply, socket}
    else
      {:error, reason} ->
        {code, message} = format_connect_error(reason)

        error_response = %{
          "code" => code,
          "message" => message
        }

        push(socket, "connect_document_error", error_response)
        {:noreply, socket}
    end
  end

  def handle_in("submitOp", %{"clientId" => client_id, "messageBatches" => batches}, socket) do
    cond do
      not socket.assigns.connected ->
        push_nack(socket, 400, "BadRequestError", "Client not connected")
        {:noreply, socket}

      socket.assigns.client_id != client_id ->
        push_nack(
          socket,
          400,
          "BadRequestError",
          "Client ID mismatch: expected #{socket.assigns.client_id}, got #{client_id}"
        )

        {:noreply, socket}

      socket.assigns.mode == "read" ->
        push_nack(socket, 403, "InvalidScopeError", "Read-only clients cannot submit operations")
        {:noreply, socket}

      not has_write_scope?(socket) ->
        push_nack(socket, 403, "InvalidScopeError", "Missing doc:write scope")
        {:noreply, socket}

      true ->
        # Validate batch size
        total_ops = batches |> List.flatten() |> length()

        if total_ops > @max_batch_size do
          push_nack(
            socket,
            400,
            "BadRequestError",
            "Batch size #{total_ops} exceeds maximum #{@max_batch_size}"
          )

          {:noreply, socket}
        else
          session_pid = socket.assigns.session_pid

          case Session.submit_ops(session_pid, client_id, batches) do
            :ok ->
              {:noreply, socket}

            {:error, nacks} ->
              push(socket, "nack", %{"clientId" => "", "nacks" => nacks})
              {:noreply, socket}
          end
        end
    end
  end

  def handle_in("submitOp", _payload, socket) do
    # Malformed submitOp - missing required fields
    push_nack(
      socket,
      400,
      "BadRequestError",
      "Malformed submitOp: missing clientId or messageBatches"
    )

    {:noreply, socket}
  end

  @doc """
  Handle signal submission from clients.

  Supports both v1 (legacy) and v2 (current) signal formats:

  ## V1 Format (Legacy)
  Content batches contain JSON-stringified envelope objects with:
  - address: routing address
  - contents: {type, content}
  - clientBroadcastSignalSequenceNumber

  ## V2 Format (Current)
  Content batches contain signal objects with optional targeting:
  - content: signal payload
  - type: signal type
  - clientConnectionNumber: client-assigned number
  - referenceSequenceNumber: for ordering context
  - targetClientId: single target (optional)
  - targetedClients: list of target clients (optional)
  - ignoredClients: list of clients to exclude (optional)
  """
  def handle_in("submitSignal", %{"clientId" => client_id, "contentBatches" => batches}, socket) do
    cond do
      not socket.assigns.connected ->
        Logger.warning("Signal from unconnected client: #{client_id}")
        {:noreply, socket}

      socket.assigns.client_id != client_id ->
        Logger.warning(
          "Signal client ID mismatch: expected #{socket.assigns.client_id}, got #{client_id}"
        )

        {:noreply, socket}

      true ->
        session_pid = socket.assigns.session_pid

        # Process signal batches - normalize v1/v2 formats
        processed_signals = process_signal_batches(batches)
        Session.submit_signals(session_pid, client_id, processed_signals)

        {:noreply, socket}
    end
  end

  def handle_in("noop", %{"clientId" => client_id, "referenceSequenceNumber" => rsn}, socket) do
    # NoOp is used by clients to update their RSN without submitting an operation
    # This helps advance the MSN when a client is idle but still connected
    if socket.assigns.connected and socket.assigns.client_id == client_id do
      session_pid = socket.assigns.session_pid
      Session.update_client_rsn(session_pid, client_id, rsn)
    end

    {:noreply, socket}
  end

  def handle_in("requestOps", %{"from" => from_sn}, socket) do
    # Client requesting operations for catch-up
    if socket.assigns.connected do
      session_pid = socket.assigns.session_pid

      case Session.get_ops_since(session_pid, from_sn) do
        {:ok, ops} when ops != [] ->
          push(socket, "op", %{
            "documentId" => socket.assigns.document_id,
            "op" => ops
          })

        {:ok, []} ->
          # No ops to send - client is caught up
          :ok

        {:error, _reason} ->
          # Could not get ops - log and continue
          Logger.warning("Failed to get ops since #{from_sn} for catch-up")
      end
    end

    {:noreply, socket}
  end

  def handle_in(event, _payload, socket) do
    Logger.debug("Unknown channel event: #{event}")
    {:noreply, socket}
  end

  @impl true
  def handle_info({:op, op_message}, socket) do
    # Check if any ops are summary ack/nack and push them as separate events
    ops = op_message["op"] || []

    {summary_events, regular_ops} =
      Enum.split_with(ops, fn op ->
        op["type"] in ["summaryAck", "summaryNack"]
      end)

    # Push summary events individually
    Enum.each(summary_events, fn event ->
      event_type = event["type"]
      push(socket, event_type, event)
    end)

    # Push regular ops (including sequenced summarize ops)
    if regular_ops != [] do
      push(socket, "op", %{op_message | "op" => regular_ops})
    end

    {:noreply, socket}
  end

  def handle_info({:signal, signal_message}, socket) do
    push(socket, "signal", signal_message)
    {:noreply, socket}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, socket) do
    if socket.assigns[:session_pid] == pid do
      Logger.warning("Session process died for document #{socket.assigns.document_id}")
      {:stop, :normal, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:send_delta_catchup, since_sn}, socket) do
    # Send delta catch-up operations to a reconnecting client
    if socket.assigns.connected and socket.assigns[:session_pid] do
      session_pid = socket.assigns.session_pid

      case Session.get_ops_since(session_pid, since_sn) do
        {:ok, ops} when ops != [] ->
          Logger.info("Sending #{length(ops)} ops for delta catch-up since SN #{since_sn}")

          push(socket, "op", %{
            "documentId" => socket.assigns.document_id,
            "op" => ops
          })

        {:ok, []} ->
          Logger.debug("No ops to send for delta catch-up (client is caught up)")

        {:error, reason} ->
          Logger.warning("Failed to get ops for delta catch-up: #{inspect(reason)}")
      end
    end

    {:noreply, socket}
  end

  def handle_info(msg, socket) do
    Logger.debug("Unhandled channel info message: #{inspect(msg)}")
    {:noreply, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    if socket.assigns[:connected] and socket.assigns[:session_pid] do
      Session.client_leave(socket.assigns.session_pid, socket.assigns.client_id)
    end

    :ok
  end

  # Private functions

  defp parse_connect_message(payload) do
    # Validate required fields
    required = ["tenantId", "id", "client", "mode"]

    missing = Enum.filter(required, fn key -> not Map.has_key?(payload, key) end)

    if Enum.empty?(missing) do
      {:ok, payload}
    else
      {:error, {:missing_fields, missing}}
    end
  end

  defp validate_tenant_document(connect_msg, socket) do
    if connect_msg["tenantId"] == socket.assigns.tenant_id and
         connect_msg["id"] == socket.assigns.document_id do
      :ok
    else
      {:error, :tenant_document_mismatch}
    end
  end

  defp get_or_create_session(socket) do
    Levee.Documents.Registry.get_or_create_session(
      socket.assigns.tenant_id,
      socket.assigns.document_id
    )
  end

  # JWT validation

  defp validate_token(connect_msg, socket) do
    token = connect_msg["token"]
    tenant_id = socket.assigns.tenant_id
    document_id = socket.assigns.document_id

    if is_nil(token) or token == "" do
      {:error, :missing_token}
    else
      with {:ok, claims} <- verify_and_wrap_error(token, tenant_id),
           :ok <- validate_claims_for_connection(claims, tenant_id, document_id) do
        {:ok, claims}
      end
    end
  end

  defp verify_and_wrap_error(token, tenant_id) do
    case JWT.verify(token, tenant_id) do
      {:ok, claims} -> {:ok, claims}
      {:error, reason} -> {:error, {:token_invalid, reason}}
    end
  end

  defp validate_claims_for_connection(claims, tenant_id, document_id) do
    cond do
      JWT.expired?(claims) ->
        {:error, :token_expired}

      claims.tenantId != tenant_id ->
        {:error, {:tenant_mismatch, claims.tenantId, tenant_id}}

      claims.documentId != document_id ->
        {:error, {:document_mismatch, claims.documentId, document_id}}

      not JWT.has_read_scope?(claims) ->
        {:error, :missing_read_scope}

      true ->
        :ok
    end
  end

  defp validate_connection_mode(connect_msg, claims) do
    mode = connect_msg["mode"] || "write"

    if mode == "write" and not JWT.has_write_scope?(claims) do
      {:error, :write_mode_without_write_scope}
    else
      :ok
    end
  end

  defp has_write_scope?(socket) do
    case socket.assigns[:claims] do
      nil -> false
      claims -> JWT.has_write_scope?(claims)
    end
  end

  defp push_nack(socket, code, type, message) do
    push(socket, "nack", %{
      "clientId" => "",
      "nacks" => [
        %{
          "operation" => nil,
          "sequenceNumber" => -1,
          "content" => %{
            "code" => code,
            "type" => type,
            "message" => message
          }
        }
      ]
    })
  end

  defp format_claims_for_response(claims) do
    %{
      "documentId" => claims.documentId,
      "scopes" => claims.scopes,
      "tenantId" => claims.tenantId,
      "user" => %{"id" => claims.user.id},
      "iat" => claims.iat,
      "exp" => claims.exp,
      "ver" => claims.ver
    }
  end

  defp format_connect_error({:missing_fields, fields}) do
    {400, "Missing required fields: #{Enum.join(fields, ", ")}"}
  end

  defp format_connect_error(:tenant_document_mismatch) do
    {400, "Tenant/document ID mismatch with topic"}
  end

  defp format_connect_error(:missing_token) do
    {401, "Missing authentication token"}
  end

  defp format_connect_error(:token_expired) do
    {401, "Token has expired"}
  end

  defp format_connect_error({:token_invalid, :invalid_signature}) do
    {401, "Invalid token signature"}
  end

  defp format_connect_error({:token_invalid, {:tenant_secret_not_found, _}}) do
    {401, "Unknown tenant"}
  end

  defp format_connect_error({:token_invalid, reason}) do
    {401, "Invalid token: #{inspect(reason)}"}
  end

  defp format_connect_error({:tenant_mismatch, _token_tenant, _request_tenant}) do
    {403, "Token not valid for this tenant"}
  end

  defp format_connect_error({:document_mismatch, _token_doc, _request_doc}) do
    {403, "Token not valid for this document"}
  end

  defp format_connect_error(:missing_read_scope) do
    {403, "Token missing required scope: doc:read"}
  end

  defp format_connect_error(:write_mode_without_write_scope) do
    {403, "Write mode requires doc:write scope"}
  end

  defp format_connect_error(:session_not_found) do
    {404, "Document session not found"}
  end

  defp format_connect_error(:session_start_failed) do
    {500, "Failed to start document session"}
  end

  defp format_connect_error(reason) when is_binary(reason), do: {400, reason}
  defp format_connect_error(reason), do: {400, inspect(reason)}

  # ─────────────────────────────────────────────────────────────────────────────
  # Signal Processing Helpers
  # ─────────────────────────────────────────────────────────────────────────────

  # Process signal batches, detecting and normalizing v1/v2 formats
  defp process_signal_batches(batches) when is_list(batches) do
    Enum.flat_map(batches, fn batch ->
      case batch do
        # Batch is a list of signals
        signals when is_list(signals) ->
          Enum.map(signals, &normalize_signal/1)

        # Single signal (not in a list)
        signal when is_map(signal) ->
          [normalize_signal(signal)]

        # JSON-stringified signal (v1 format)
        signal when is_binary(signal) ->
          case Jason.decode(signal) do
            {:ok, decoded} -> [normalize_signal(decoded)]
            {:error, _} -> []
          end

        _ ->
          []
      end
    end)
  end

  defp process_signal_batches(_), do: []

  # Normalize a signal to a consistent internal format
  # Handles both v1 and v2 signal formats
  defp normalize_signal(signal) when is_map(signal) do
    # Detect format: v1 has "address" and "contents", v2 has "content" directly
    is_v1 = Map.has_key?(signal, "address") or Map.has_key?(signal, "contents")

    if is_v1 do
      normalize_v1_signal(signal)
    else
      normalize_v2_signal(signal)
    end
  end

  defp normalize_signal(signal) when is_binary(signal) do
    # Try to parse JSON string (v1 format typically sends stringified envelopes)
    case Jason.decode(signal) do
      {:ok, decoded} -> normalize_signal(decoded)
      {:error, _} -> %{"content" => signal, "type" => nil}
    end
  end

  defp normalize_signal(_), do: %{"content" => nil, "type" => nil}

  # Normalize v1 signal format to internal format
  # V1: {address, contents: {type, content}, clientBroadcastSignalSequenceNumber}
  defp normalize_v1_signal(signal) do
    contents = signal["contents"] || %{}

    %{
      "content" => contents["content"],
      "type" => contents["type"],
      # V1 doesn't have targeting, so these are nil
      "targetClientId" => nil,
      "targetedClients" => nil,
      "ignoredClients" => nil,
      # Map v1 sequence number to connection number
      "clientConnectionNumber" => signal["clientBroadcastSignalSequenceNumber"]
    }
  end

  # Normalize v2 signal format (already in correct format, just ensure all fields)
  defp normalize_v2_signal(signal) do
    # Check if this is a clientBroadcastSignalEnvelope (wrapper with targeting)
    # or a direct signal
    inner_signal = signal["signal"] || signal

    %{
      "content" => inner_signal["content"],
      "type" => inner_signal["type"],
      "clientConnectionNumber" => inner_signal["clientConnectionNumber"],
      "referenceSequenceNumber" => inner_signal["referenceSequenceNumber"],
      "targetClientId" => inner_signal["targetClientId"],
      # Targeting from envelope level
      "targetedClients" => signal["targetedClients"],
      "ignoredClients" => signal["ignoredClients"]
    }
  end
end
