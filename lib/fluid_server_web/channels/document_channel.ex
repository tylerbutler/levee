defmodule FluidServerWeb.DocumentChannel do
  @moduledoc """
  Phoenix Channel for Fluid Framework document collaboration.

  Handles the WebSocket protocol events:
  - connect_document: Client joins a document session
  - submitOp: Client submits operations
  - submitSignal: Client sends signals
  - Delta catch-up on reconnection
  """

  use Phoenix.Channel

  alias FluidServer.Documents.Session
  alias FluidServer.Protocol.Bridge

  require Logger

  # 16MB default
  @max_message_size 16 * 1024 * 1024
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
         {:ok, session_pid} <- get_or_create_session(socket),
         {:ok, client_id, connected_response} <- Session.client_join(session_pid, connect_msg) do
      # Check if this is a reconnection with a last seen SN
      last_seen_sn = connect_msg["lastSeenSequenceNumber"]

      # Update socket with client info
      socket =
        socket
        |> assign(:client_id, client_id)
        |> assign(:mode, connect_msg["mode"] || "write")
        |> assign(:connected, true)
        |> assign(:session_pid, session_pid)
        |> assign(:last_seen_sn, last_seen_sn)

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
        error_response = %{
          "code" => error_code_for_reason(reason),
          "message" => format_error(reason)
        }

        push(socket, "connect_document_error", error_response)
        {:noreply, socket}
    end
  end

  def handle_in("submitOp", %{"clientId" => client_id, "messageBatches" => batches}, socket) do
    cond do
      not socket.assigns.connected ->
        push(socket, "nack", %{
          "clientId" => "",
          "nacks" => [Bridge.build_nack_unknown_client(client_id)]
        })

        {:noreply, socket}

      socket.assigns.client_id != client_id ->
        push(socket, "nack", %{
          "clientId" => "",
          "nacks" => [
            %{
              "operation" => nil,
              "sequenceNumber" => -1,
              "content" => %{
                "code" => 400,
                "type" => "BadRequestError",
                "message" =>
                  "Client ID mismatch: expected #{socket.assigns.client_id}, got #{client_id}"
              }
            }
          ]
        })

        {:noreply, socket}

      socket.assigns.mode == "read" ->
        push(socket, "nack", %{
          "clientId" => "",
          "nacks" => [Bridge.build_nack_read_only()]
        })

        {:noreply, socket}

      true ->
        # Validate batch size
        total_ops = batches |> List.flatten() |> length()

        if total_ops > @max_batch_size do
          push(socket, "nack", %{
            "clientId" => "",
            "nacks" => [
              %{
                "operation" => nil,
                "sequenceNumber" => -1,
                "content" => %{
                  "code" => 400,
                  "type" => "BadRequestError",
                  "message" => "Batch size #{total_ops} exceeds maximum #{@max_batch_size}"
                }
              }
            ]
          })

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
    push(socket, "nack", %{
      "clientId" => "",
      "nacks" => [
        %{
          "operation" => nil,
          "sequenceNumber" => -1,
          "content" => %{
            "code" => 400,
            "type" => "BadRequestError",
            "message" => "Malformed submitOp: missing clientId or messageBatches"
          }
        }
      ]
    })

    {:noreply, socket}
  end

  def handle_in("submitSignal", %{"clientId" => client_id, "contentBatches" => batches}, socket) do
    if socket.assigns.connected and socket.assigns.client_id == client_id do
      session_pid = socket.assigns.session_pid
      Session.submit_signals(session_pid, client_id, batches)
    end

    {:noreply, socket}
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
    push(socket, "op", op_message)
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
    tenant_id = socket.assigns.tenant_id
    document_id = socket.assigns.document_id

    case FluidServer.Documents.Registry.get_or_create_session(tenant_id, document_id) do
      {:ok, pid} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp format_error({:missing_fields, fields}) do
    "Missing required fields: #{Enum.join(fields, ", ")}"
  end

  defp format_error(:tenant_document_mismatch) do
    "Tenant/document ID mismatch with topic"
  end

  defp format_error(:session_not_found) do
    "Document session not found"
  end

  defp format_error(:session_start_failed) do
    "Failed to start document session"
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  defp error_code_for_reason({:missing_fields, _}), do: 400
  defp error_code_for_reason(:tenant_document_mismatch), do: 400
  defp error_code_for_reason(:session_not_found), do: 404
  defp error_code_for_reason(:session_start_failed), do: 500
  defp error_code_for_reason(_), do: 400
end
