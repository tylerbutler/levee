defmodule FluidServer.Documents.Session do
  @moduledoc """
  GenServer managing a single document's collaboration session.

  This is the authoritative source for:
  - Sequence number assignment
  - Connected client tracking
  - Operation ordering and broadcast
  - Signal relay
  - Operation history for delta catch-up

  Uses the Gleam protocol module for sequence number logic.
  """

  use GenServer

  alias FluidServer.Protocol.Bridge

  require Logger

  # 16MB
  @max_message_size 16 * 1024 * 1024
  # 64KB
  @block_size 64 * 1024
  # Maximum operations to keep in history for catch-up
  @max_history_size 1000

  defstruct [
    :tenant_id,
    :document_id,
    :sequence_state,
    # %{client_id => %{pid: pid, client: client_info, mode: mode, last_seen_sn: sn}}
    :clients,
    :client_counter,
    # List of sequenced operations for delta catch-up (newest first)
    :op_history
  ]

  # Client API

  def start_link({tenant_id, document_id}) do
    GenServer.start_link(__MODULE__, {tenant_id, document_id},
      name: via_tuple(tenant_id, document_id)
    )
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

  @doc """
  Get operations since a given sequence number for delta catch-up.
  Returns operations with SN > since_sn.
  """
  def get_ops_since(pid, since_sn) do
    GenServer.call(pid, {:get_ops_since, since_sn})
  end

  @doc """
  Update client's last seen sequence number (for NoOp/heartbeat handling).
  """
  def update_client_rsn(pid, client_id, rsn) do
    GenServer.cast(pid, {:update_client_rsn, client_id, rsn})
  end

  @doc """
  Get current session state summary (for debugging/monitoring).
  """
  def get_state_summary(pid) do
    GenServer.call(pid, :get_state_summary)
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
      client_counter: 0,
      op_history: []
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

    # Store client info with last seen SN for catch-up support
    client_info = %{
      pid: channel_pid,
      client: connect_msg["client"],
      mode: mode,
      monitor_ref: Process.monitor(channel_pid),
      last_seen_sn: current_sn
    }

    new_clients = Map.put(state.clients, client_id, client_info)

    # Generate and sequence a system "join" message
    {join_message, final_sequence_state, updated_history} =
      generate_system_message(
        "join",
        client_id,
        connect_msg["client"],
        new_sequence_state,
        state.op_history
      )

    # Build IConnected response with initial clients list
    connected_response =
      build_connected_response(
        client_id,
        mode,
        connect_msg,
        state,
        final_sequence_state,
        new_clients
      )

    # Broadcast join message to all clients (including the new one, as per protocol)
    broadcast_ops(state.document_id, [join_message], new_clients)

    new_state = %{
      state
      | sequence_state: final_sequence_state,
        clients: new_clients,
        client_counter: state.client_counter + 1,
        op_history: updated_history
    }

    {:reply, {:ok, client_id, connected_response}, new_state}
  end

  def handle_call({:submit_ops, client_id, op_batches}, _from, state) do
    # Verify client exists and is in write mode
    case Map.get(state.clients, client_id) do
      nil ->
        nack = Bridge.build_nack_unknown_client(client_id)
        {:reply, {:error, [nack]}, state}

      %{mode: "read"} ->
        nack = Bridge.build_nack_read_only()
        {:reply, {:error, [nack]}, state}

      _client_info ->
        case process_ops(client_id, op_batches, state) do
          {:ok, sequenced_ops, new_state} ->
            # Broadcast ops to all connected clients
            broadcast_ops(state.document_id, sequenced_ops, new_state.clients)
            {:reply, :ok, new_state}

          {:error, nacks, new_state} ->
            {:reply, {:error, nacks}, new_state}
        end
    end
  end

  def handle_call({:get_ops_since, since_sn}, _from, state) do
    # Filter operations from history that have SN > since_sn
    # History is stored newest-first, so we need to reverse for chronological order
    ops =
      state.op_history
      |> Enum.filter(fn op -> op["sequenceNumber"] > since_sn end)
      |> Enum.reverse()

    {:reply, {:ok, ops}, state}
  end

  def handle_call(:get_state_summary, _from, state) do
    summary = %{
      tenant_id: state.tenant_id,
      document_id: state.document_id,
      current_sn: Bridge.current_sn(state.sequence_state),
      current_msn: Bridge.current_msn(state.sequence_state),
      client_count: map_size(state.clients),
      client_ids: Map.keys(state.clients),
      history_size: length(state.op_history)
    }

    {:reply, {:ok, summary}, state}
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

        # Generate and sequence a system "leave" message
        {leave_message, final_sequence_state, updated_history} =
          generate_system_message(
            "leave",
            client_id,
            # For leave, content is just the client_id
            client_id,
            new_sequence_state,
            state.op_history
          )

        # Broadcast leave message to remaining clients
        if map_size(new_clients) > 0 do
          broadcast_ops(state.document_id, [leave_message], new_clients)
        end

        new_state = %{
          state
          | sequence_state: final_sequence_state,
            clients: new_clients,
            op_history: updated_history
        }

        # If no clients left, consider stopping
        if map_size(new_clients) == 0 do
          Logger.info("No clients left for #{state.tenant_id}/#{state.document_id}, session idle")
        end

        {:noreply, new_state}
    end
  end

  def handle_cast({:update_client_rsn, client_id, rsn}, state) do
    case Bridge.update_client_rsn(state.sequence_state, client_id, rsn) do
      {:ok, new_sequence_state} ->
        # Also update client's last_seen_sn
        new_clients =
          Map.update(state.clients, client_id, nil, fn client_info ->
            if client_info, do: %{client_info | last_seen_sn: rsn}, else: nil
          end)
          |> Map.reject(fn {_k, v} -> is_nil(v) end)

        {:noreply, %{state | sequence_state: new_sequence_state, clients: new_clients}}

      {:error, _reason} ->
        # Client not found or invalid RSN - ignore silently
        {:noreply, state}
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

  defp build_connected_response(client_id, mode, connect_msg, _state, sequence_state, clients) do
    current_sn = Bridge.current_sn(sequence_state)

    # Build initial clients list (all clients except the joining one)
    initial_clients =
      clients
      |> Map.delete(client_id)
      |> Enum.map(fn {cid, info} ->
        %{
          "clientId" => cid,
          "client" => info.client,
          "mode" => info.mode
        }
      end)

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
      "initialClients" => initial_clients,
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
            # Add to history (newest first) and trim if needed
            updated_history = add_to_history(sequenced_op, acc_state.op_history)
            new_state = %{acc_state | sequence_state: new_seq_state, op_history: updated_history}
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

  defp add_to_history(op, history) do
    # Add operation to front (newest first) and trim to max size
    [op | history]
    |> Enum.take(@max_history_size)
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

  # Generate a system message (join/leave) with proper sequencing
  # System messages have clientId: nil and get their own sequence number
  defp generate_system_message(message_type, client_id, content, sequence_state, history) do
    # System messages get the next sequence number
    # We increment SN directly since system messages don't go through normal client sequencing
    current_sn = Bridge.current_sn(sequence_state)
    new_sn = current_sn + 1
    msn = Bridge.current_msn(sequence_state)

    # Build the system message content based on type
    message_content =
      case message_type do
        "join" ->
          %{
            "clientId" => client_id,
            "detail" => content
          }

        "leave" ->
          client_id

        _ ->
          content
      end

    system_message = %{
      # System messages have no client ID
      "clientId" => nil,
      "sequenceNumber" => new_sn,
      "minimumSequenceNumber" => msn,
      # System messages don't have CSN
      "clientSequenceNumber" => -1,
      "referenceSequenceNumber" => current_sn,
      "type" => message_type,
      "contents" => message_content,
      "metadata" => nil,
      "timestamp" => System.system_time(:millisecond),
      # System messages include data field
      "data" => Jason.encode!(message_content)
    }

    # Update sequence state to reflect the new SN
    # We use from_checkpoint to update the SN since we're manually incrementing
    updated_sequence_state = Bridge.sequence_state_from_checkpoint(new_sn, msn)

    # Re-register all clients with their current RSN
    # This is needed because from_checkpoint creates a fresh state
    final_sequence_state =
      Enum.reduce(Bridge.connected_clients(sequence_state), updated_sequence_state, fn cid, acc ->
        # Use the current SN as the join RSN for existing clients
        Bridge.client_join(acc, cid, current_sn)
      end)

    # Add to history
    updated_history = add_to_history(system_message, history)

    {system_message, final_sequence_state, updated_history}
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
