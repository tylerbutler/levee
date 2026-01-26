defmodule FluidServerWeb.DocumentChannel do
  @moduledoc """
  Phoenix Channel for Fluid Framework document collaboration.

  Handles the WebSocket protocol events:
  - connect_document: Client joins a document session
  - submitOp: Client submits operations
  - submitSignal: Client sends signals
  """

  use Phoenix.Channel

  alias FluidServer.Documents.Session
  alias FluidServer.Protocol.Bridge

  require Logger

  @max_message_size 16 * 1024 * 1024  # 16MB default
  @block_size 64 * 1024  # 64KB

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

      # Update socket with client info
      socket =
        socket
        |> assign(:client_id, client_id)
        |> assign(:mode, connect_msg["mode"] || "write")
        |> assign(:connected, true)
        |> assign(:session_pid, session_pid)

      # Monitor the session process
      Process.monitor(session_pid)

      push(socket, "connect_document_success", connected_response)
      {:noreply, socket}
    else
      {:error, reason} ->
        error_response = %{
          "code" => 400,
          "message" => format_error(reason)
        }
        push(socket, "connect_document_error", error_response)
        {:noreply, socket}
    end
  end

  def handle_in("submitOp", %{"clientId" => client_id, "messageBatches" => batches}, socket) do
    if socket.assigns.connected and socket.assigns.client_id == client_id do
      session_pid = socket.assigns.session_pid

      case Session.submit_ops(session_pid, client_id, batches) do
        :ok ->
          {:noreply, socket}

        {:error, nacks} ->
          push(socket, "nack", %{"clientId" => "", "nacks" => nacks})
          {:noreply, socket}
      end
    else
      push(socket, "nack", %{
        "clientId" => "",
        "nacks" => [%{
          "operation" => nil,
          "sequenceNumber" => -1,
          "content" => %{
            "code" => 400,
            "type" => "BadRequestError",
            "message" => "Client not connected or ID mismatch"
          }
        }]
      })
      {:noreply, socket}
    end
  end

  def handle_in("submitSignal", %{"clientId" => client_id, "contentBatches" => batches}, socket) do
    if socket.assigns.connected and socket.assigns.client_id == client_id do
      session_pid = socket.assigns.session_pid
      Session.submit_signals(session_pid, client_id, batches)
    end
    {:noreply, socket}
  end

  def handle_in(_event, _payload, socket) do
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

  def handle_info(_msg, socket) do
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

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
