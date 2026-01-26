defmodule FluidServer.Documents.Session do
  @moduledoc """
  GenServer managing a single document's collaboration session.

  This is the authoritative source for:
  - Sequence number assignment
  - Connected client tracking
  - Operation ordering and broadcast
  - Signal relay

  Uses the Gleam protocol module for sequence number logic.
  """

  use GenServer

  alias FluidServer.Protocol.Bridge

  require Logger

  @max_message_size 16 * 1024 * 1024  # 16MB
  @block_size 64 * 1024  # 64KB

  defstruct [
    :tenant_id,
    :document_id,
    :sequence_state,
    :clients,  # %{client_id => %{pid: pid, client: client_info, mode: mode}}
    :client_counter
  ]

  # Client API

  def start_link({tenant_id, document_id}) do
    GenServer.start_link(__MODULE__, {tenant_id, document_id}, name: via_tuple(tenant_id, document_id))
  end

  def client_join(pid, connect_msg) do
    GenServer.call(pid, {:client_join, connect_msg, self()})
  end

  def client_leave(pid, client_id) do
    GenServer.cast(pid, {:client_leave, client_id})
  end

  def submit_ops(pid, client_id, op_batches) do
    GenServer.call(pid, {:submit_ops, client_id, op_batches})
  end

  def submit_signals(pid, client_id, signal_batches) do
    GenServer.cast(pid, {:submit_signals, client_id, signal_batches})
  end

  # Server callbacks

  @impl true
  def init({tenant_id, document_id}) do
    Logger.info("Starting session for #{tenant_id}/#{document_id}")

    # Initialize sequence state using Gleam
    sequence_state = Bridge.new_sequence_state()

    state = %__MODULE__{
      tenant_id: tenant_id,
      document_id: document_id,
      sequence_state: sequence_state,
      clients: %{},
      client_counter: 0
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:client_join, connect_msg, channel_pid}, _from, state) do
    # Generate client ID
    client_id = generate_client_id(state)
    mode = connect_msg["mode"] || "write"

    # Get current sequence number as the join RSN
    current_sn = Bridge.current_sn(state.sequence_state)

    # Register client in sequence state
    new_sequence_state = Bridge.client_join(state.sequence_state, client_id, current_sn)

    # Store client info
    client_info = %{
      pid: channel_pid,
      client: connect_msg["client"],
      mode: mode,
      monitor_ref: Process.monitor(channel_pid)
    }

    new_clients = Map.put(state.clients, client_id, client_info)

    # Build IConnected response
    connected_response = build_connected_response(client_id, mode, connect_msg, state, new_sequence_state)

    # Broadcast join signal to other clients
    broadcast_client_join(client_id, connect_msg["client"], new_clients)

    new_state = %{state |
      sequence_state: new_sequence_state,
      clients: new_clients,
      client_counter: state.client_counter + 1
    }

    {:reply, {:ok, client_id, connected_response}, new_state}
  end

  def handle_call({:submit_ops, client_id, op_batches}, _from, state) do
    case process_ops(client_id, op_batches, state) do
      {:ok, sequenced_ops, new_state} ->
        # Broadcast ops to all connected clients
        broadcast_ops(state.document_id, sequenced_ops, new_state.clients)
        {:reply, :ok, new_state}

      {:error, nacks, new_state} ->
        {:reply, {:error, nacks}, new_state}
    end
  end

  @impl true
  def handle_cast({:client_leave, client_id}, state) do
    case Map.get(state.clients, client_id) do
      nil ->
        {:noreply, state}

      client_info ->
        # Demonitor the channel process
        Process.demonitor(client_info.monitor_ref, [:flush])

        # Remove from sequence state
        new_sequence_state = Bridge.client_leave(state.sequence_state, client_id)
        new_clients = Map.delete(state.clients, client_id)

        # Broadcast leave signal
        broadcast_client_leave(client_id, new_clients)

        new_state = %{state |
          sequence_state: new_sequence_state,
          clients: new_clients
        }

        # If no clients left, consider stopping
        if map_size(new_clients) == 0 do
          Logger.info("No clients left for #{state.tenant_id}/#{state.document_id}, session idle")
        end

        {:noreply, new_state}
    end
  end

  def handle_cast({:submit_signals, client_id, signal_batches}, state) do
    # Relay signals to appropriate clients
    Enum.each(signal_batches, fn signal ->
      broadcast_signal(client_id, signal, state.clients)
    end)
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    # Find client by monitor ref and remove them
    case Enum.find(state.clients, fn {_id, info} -> info.monitor_ref == ref end) do
      {client_id, _info} ->
        handle_cast({:client_leave, client_id}, state)

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Private functions

  defp via_tuple(tenant_id, document_id) do
    {:via, Registry, {FluidServer.SessionRegistry, {tenant_id, document_id}}}
  end

  defp generate_client_id(state) do
    "#{state.tenant_id}_#{state.document_id}_#{state.client_counter + 1}"
  end

  defp build_connected_response(client_id, mode, connect_msg, _state, sequence_state) do
    current_sn = Bridge.current_sn(sequence_state)

    %{
      "claims" => build_mock_claims(connect_msg),
      "clientId" => client_id,
      "existing" => true,
      "maxMessageSize" => @max_message_size,
      "mode" => mode,
      "serviceConfiguration" => %{
        "blockSize" => @block_size,
        "maxMessageSize" => @max_message_size
      },
      "initialClients" => [],  # TODO: populate with current clients
      "initialMessages" => [],
      "initialSignals" => [],
      "supportedVersions" => ["^0.1.0"],
      "supportedFeatures" => %{
        "submit_signals_v2" => true
      },
      "version" => "0.1.0",
      "checkpointSequenceNumber" => current_sn
    }
  end

  defp build_mock_claims(connect_msg) do
    # In production, this would come from JWT validation
    %{
      "documentId" => connect_msg["id"],
      "scopes" => ["doc:read", "doc:write"],
      "tenantId" => connect_msg["tenantId"],
      "user" => connect_msg["client"]["user"] || %{"id" => "anonymous"},
      "iat" => System.system_time(:second),
      "exp" => System.system_time(:second) + 3600,
      "ver" => "1.0"
    }
  end

  defp process_ops(client_id, op_batches, state) do
    # Flatten batches
    ops = List.flatten(op_batches)

    # Process each op through sequencing
    {sequenced_ops, nacks, final_state} =
      Enum.reduce(ops, {[], [], state}, fn op, {acc_ops, acc_nacks, acc_state} ->
        csn = op["clientSequenceNumber"] || 0
        rsn = op["referenceSequenceNumber"] || 0

        case Bridge.assign_sequence_number(acc_state.sequence_state, client_id, csn, rsn) do
          {:ok, new_seq_state, assigned_sn, msn} ->
            sequenced_op = build_sequenced_op(op, client_id, assigned_sn, msn)
            new_state = %{acc_state | sequence_state: new_seq_state}
            {[sequenced_op | acc_ops], acc_nacks, new_state}

          {:error, reason} ->
            nack = build_nack(op, reason)
            {acc_ops, [nack | acc_nacks], acc_state}
        end
      end)

    if Enum.empty?(nacks) do
      {:ok, Enum.reverse(sequenced_ops), final_state}
    else
      {:error, Enum.reverse(nacks), final_state}
    end
  end

  defp build_sequenced_op(op, client_id, sn, msn) do
    %{
      "clientId" => client_id,
      "sequenceNumber" => sn,
      "minimumSequenceNumber" => msn,
      "clientSequenceNumber" => op["clientSequenceNumber"] || 0,
      "referenceSequenceNumber" => op["referenceSequenceNumber"] || 0,
      "type" => op["type"] || "op",
      "contents" => op["contents"],
      "metadata" => op["metadata"],
      "timestamp" => System.system_time(:millisecond)
    }
  end

  defp build_nack(op, reason) do
    {code, type, message} = format_sequence_error(reason)

    %{
      "operation" => op,
      "sequenceNumber" => -1,
      "content" => %{
        "code" => code,
        "type" => type,
        "message" => message
      }
    }
  end

  defp format_sequence_error({:invalid_csn, expected, received}) do
    {400, "BadRequestError", "Invalid CSN: expected > #{expected}, received #{received}"}
  end

  defp format_sequence_error({:invalid_rsn, current_sn, received_rsn}) do
    {400, "BadRequestError", "Invalid RSN: current SN is #{current_sn}, received #{received_rsn}"}
  end

  defp format_sequence_error({:unknown_client, client_id}) do
    {400, "BadRequestError", "Unknown client: #{client_id}"}
  end

  defp format_sequence_error(reason) do
    {400, "BadRequestError", "Sequencing error: #{inspect(reason)}"}
  end

  defp broadcast_ops(document_id, ops, clients) do
    message = %{
      "documentId" => document_id,
      "op" => ops
    }

    Enum.each(clients, fn {_client_id, client_info} ->
      send(client_info.pid, {:op, message})
    end)
  end

  defp broadcast_client_join(new_client_id, client_info, clients) do
    signal = %{
      "clientId" => nil,
      "content" => Jason.encode!(%{
        "type" => "join",
        "content" => %{
          "clientId" => new_client_id,
          "client" => client_info
        }
      })
    }

    # Send to all clients except the joining one
    Enum.each(clients, fn {client_id, info} ->
      if client_id != new_client_id do
        send(info.pid, {:signal, signal})
      end
    end)
  end

  defp broadcast_client_leave(leaving_client_id, clients) do
    signal = %{
      "clientId" => nil,
      "content" => Jason.encode!(%{
        "type" => "leave",
        "content" => leaving_client_id
      })
    }

    Enum.each(clients, fn {_client_id, info} ->
      send(info.pid, {:signal, signal})
    end)
  end

  defp broadcast_signal(sender_client_id, signal, clients) do
    # Check if targeted
    target_client_id = get_in(signal, ["targetClientId"])

    message = %{
      "clientId" => sender_client_id,
      "content" => signal["content"],
      "type" => signal["type"]
    }

    if target_client_id do
      # Targeted signal
      case Map.get(clients, target_client_id) do
        nil -> :ok
        info -> send(info.pid, {:signal, message})
      end
    else
      # Broadcast to all except sender
      Enum.each(clients, fn {client_id, info} ->
        if client_id != sender_client_id do
          send(info.pid, {:signal, message})
        end
      end)
    end
  end
end
