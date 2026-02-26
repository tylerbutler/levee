defmodule Levee.Documents.Session do
  @moduledoc """
  GenServer managing a single document's collaboration session.

  This is the authoritative source for:
  - Sequence number assignment
  - Connected client tracking
  - Operation ordering and broadcast
  - Signal relay (v1 and v2 formats with targeting)
  - Operation history for delta catch-up

  Uses the Gleam protocol module for sequence number logic.

  ## Signal Handling

  Supports two signal formats:
  - **V1 (Legacy)**: Simple broadcast with `{clientId, content}` format
  - **V2 (Current)**: Enhanced format with targeting support:
    - `targetedClients`: Optional list of specific client IDs to receive the signal
    - `ignoredClients`: Optional list of client IDs to exclude from receiving

  ## Feature Negotiation

  The server advertises `submit_signals_v2: true` in the connect_document_success
  response, indicating v2 signal format support.
  """

  use GenServer

  alias Levee.Protocol.Bridge

  require Logger

  # 16MB
  @max_message_size 16 * 1024 * 1024
  # 64KB
  @block_size 64 * 1024
  # Maximum operations to keep in history for catch-up
  @max_history_size 1000

  # Supported features advertised to clients
  @supported_features %{
    "submit_signals_v2" => true
  }

  # Supported protocol versions
  @supported_versions ["^0.1.0", "^1.0.0"]

  defstruct [
    :tenant_id,
    :document_id,
    :sequence_state,
    # %{client_id => %{pid: pid, client: client_info, mode: mode, last_seen_sn: sn, features: map}}
    :clients,
    :client_counter,
    # List of sequenced operations for delta catch-up (newest first)
    :op_history,
    # Summary state
    # %{sequence_number => %{client_id: _, contents: _, timestamp: _}}
    :pending_summaries,
    # Latest acknowledged summary info
    :latest_summary
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

  def client_join(pid, connect_msg, channel_pid) do
    GenServer.call(pid, {:client_join, connect_msg, channel_pid})
  end

  def client_leave(pid, client_id) do
    GenServer.cast(pid, {:client_leave, client_id})
  end

  def submit_ops(pid, client_id, op_batches) do
    GenServer.call(pid, {:submit_ops, client_id, op_batches})
  end

  @doc """
  Submit signals to be relayed to other clients.

  Supports both v1 (legacy) and v2 (current) signal formats:

  ## V1 Format (Legacy)
  Simple content broadcast: `{clientId, content}` - broadcasts to all other clients

  ## V2 Format (Current)
  Enhanced format with targeting support:
  - `targetedClients`: Optional list of specific client IDs to receive the signal
  - `ignoredClients`: Optional list of client IDs to exclude from receiving
  - If neither specified, broadcasts to all clients except sender

  ## Parameters
  - `pid`: Session process PID
  - `client_id`: The sending client's ID
  - `signal_batches`: List of signal contents to relay
  """
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

  @doc """
  Get the latest summary context for this document.
  Returns nil if no summary exists.
  """
  def get_summary_context(pid) do
    GenServer.call(pid, :get_summary_context)
  end

  # Server callbacks

  @impl true
  def init({tenant_id, document_id}) do
    Logger.info("Starting session for #{tenant_id}/#{document_id}")

    # Initialize sequence state using Gleam
    sequence_state = Bridge.new_sequence_state()

    # Try to load latest summary from storage
    latest_summary = load_latest_summary(tenant_id, document_id)

    state = %__MODULE__{
      tenant_id: tenant_id,
      document_id: document_id,
      sequence_state: sequence_state,
      clients: %{},
      client_counter: 0,
      op_history: [],
      pending_summaries: %{},
      latest_summary: latest_summary
    }

    {:ok, state}
  end

  defp load_latest_summary(tenant_id, document_id) do
    case Levee.Storage.get_latest_summary(tenant_id, document_id) do
      {:ok, summary} ->
        %{
          handle: summary.handle,
          sequence_number: summary.sequence_number
        }

      {:error, :not_found} ->
        nil
    end
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
    # Also store negotiated features for targeting decisions
    client_features = connect_msg["supportedFeatures"] || %{}

    client_info = %{
      pid: channel_pid,
      client: connect_msg["client"],
      mode: mode,
      monitor_ref: Process.monitor(channel_pid),
      last_seen_sn: current_sn,
      features: Bridge.negotiate_features(@supported_features, client_features)
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

    # Build IConnected response with initial clients list and summary context
    connected_response =
      build_connected_response(
        client_id,
        mode,
        connect_msg,
        state,
        final_sequence_state,
        new_clients,
        state.latest_summary
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

  def handle_call(:get_summary_context, _from, state) do
    {:reply, {:ok, state.latest_summary}, state}
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
        new_clients =
          case Map.fetch(state.clients, client_id) do
            {:ok, client_info} ->
              Map.put(state.clients, client_id, %{client_info | last_seen_sn: rsn})

            :error ->
              state.clients
          end

        {:noreply, %{state | sequence_state: new_sequence_state, clients: new_clients}}

      {:error, _reason} ->
        {:noreply, state}
    end
  end

  def handle_cast({:submit_signals, client_id, signal_batches}, state) do
    # Verify client exists
    case Map.get(state.clients, client_id) do
      nil ->
        Logger.warning("Signal from unknown client: #{client_id}")
        {:noreply, state}

      _client_info ->
        # Relay signals to appropriate clients based on format (v1/v2)
        Enum.each(signal_batches, fn signal ->
          broadcast_signal(client_id, signal, state.clients, state.document_id)
        end)

        {:noreply, state}
    end
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
    {:via, Registry, {Levee.SessionRegistry, {tenant_id, document_id}}}
  end

  defp generate_client_id(state) do
    "#{state.tenant_id}_#{state.document_id}_#{state.client_counter + 1}"
  end

  defp build_connected_response(
         client_id,
         mode,
         connect_msg,
         _state,
         sequence_state,
         clients,
         latest_summary
       ) do
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

    # Negotiate features based on client's supported features
    client_features = connect_msg["supportedFeatures"] || %{}
    negotiated_features = Bridge.negotiate_features(@supported_features, client_features)

    # Negotiate protocol version based on client's supported versions
    client_versions = connect_msg["versions"] || []
    negotiated_version = Bridge.negotiate_version(@supported_versions, client_versions)

    # Build base response
    response = %{
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
      "supportedVersions" => @supported_versions,
      "supportedFeatures" => negotiated_features,
      "version" => negotiated_version,
      "checkpointSequenceNumber" => current_sn
    }

    # Add summary context if available
    case latest_summary do
      %{handle: handle, sequence_number: summary_sn} ->
        Map.put(response, "summaryContext", %{
          "handle" => handle,
          "sequenceNumber" => summary_sn
        })

      nil ->
        response
    end
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
            # Check if this is a summarize op
            op_type = op["type"] || "op"

            if op_type == "summarize" do
              # Handle summarize op specially
              process_summarize_op(
                op,
                client_id,
                assigned_sn,
                msn,
                new_seq_state,
                acc_ops,
                acc_nacks,
                acc_state
              )
            else
              sequenced_op = Bridge.build_sequenced_op(op, client_id, assigned_sn, msn)
              # Add to history (newest first) and trim if needed
              updated_history =
                Bridge.add_to_history(sequenced_op, acc_state.op_history, @max_history_size)

              new_state = %{
                acc_state
                | sequence_state: new_seq_state,
                  op_history: updated_history
              }

              {[sequenced_op | acc_ops], acc_nacks, new_state}
            end

          {:error, reason} ->
            nack = Bridge.build_nack_from_reason(op, reason)
            {acc_ops, [nack | acc_nacks], acc_state}
        end
      end)

    if Enum.empty?(nacks) do
      {:ok, Enum.reverse(sequenced_ops), final_state}
    else
      {:error, Enum.reverse(nacks), final_state}
    end
  end

  defp process_summarize_op(
         op,
         client_id,
         assigned_sn,
         msn,
         new_seq_state,
         acc_ops,
         acc_nacks,
         acc_state
       ) do
    contents = op["contents"] || %{}

    case Bridge.validate_summarize_contents(contents) do
      :ok ->
        {:ok, summary_handle} =
          store_summary(acc_state.tenant_id, acc_state.document_id, contents, assigned_sn)

        summary_ack = Bridge.build_summary_ack(summary_handle, assigned_sn, msn)
        sequenced_summarize = Bridge.build_sequenced_op(op, client_id, assigned_sn, msn)

        updated_history =
          Bridge.add_to_history(
            summary_ack,
            Bridge.add_to_history(sequenced_summarize, acc_state.op_history, @max_history_size),
            @max_history_size
          )

        new_state = %{
          acc_state
          | sequence_state: new_seq_state,
            op_history: updated_history,
            latest_summary: %{handle: summary_handle, sequence_number: assigned_sn}
        }

        {[summary_ack, sequenced_summarize | acc_ops], acc_nacks, new_state}

      {:error, reason} ->
        nack = Bridge.build_nack_from_reason(op, {:invalid_summarize, reason})
        {acc_ops, [nack | acc_nacks], acc_state}
    end
  end

  defp store_summary(tenant_id, document_id, contents, sequence_number) do
    handle = contents["handle"]
    message = contents["message"]
    parents = contents["parents"] || []
    head = contents["head"]

    # Create summary record
    summary = %{
      handle: handle,
      sequence_number: sequence_number,
      tree_sha: head,
      commit_sha: nil,
      parent_handle: List.first(parents),
      message: message
    }

    {:ok, _stored} = Levee.Storage.store_summary(tenant_id, document_id, summary)
    {:ok, handle}
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

    # Re-register all clients with the new SN as their join RSN
    # This is needed because from_checkpoint creates a fresh state
    final_sequence_state =
      Enum.reduce(Bridge.connected_clients(sequence_state), updated_sequence_state, fn cid, acc ->
        # Use new_sn since from_checkpoint reset the state to this sequence number
        Bridge.client_join(acc, cid, new_sn)
      end)

    # Add to history
    updated_history = Bridge.add_to_history(system_message, history, @max_history_size)

    {system_message, final_sequence_state, updated_history}
  end

  # Broadcast a signal to appropriate clients based on format (v1/v2) and targeting
  defp broadcast_signal(sender_client_id, signal, clients, _document_id) do
    # Detect signal format and extract targeting info
    {message, recipients} = process_signal_targeting(sender_client_id, signal, clients)

    # Send to each recipient
    Enum.each(recipients, fn client_id ->
      case Map.get(clients, client_id) do
        nil -> :ok
        info -> send(info.pid, {:signal, message})
      end
    end)
  end

  # Process signal targeting to determine recipients
  # Returns {signal_message, list_of_recipient_client_ids}
  defp process_signal_targeting(sender_client_id, signal, clients) do
    all_client_ids = Map.keys(clients)

    # Build the signal message with optional fields
    message =
      %{
        "clientId" => sender_client_id,
        "content" => signal["content"],
        "type" => signal["type"]
      }
      |> put_if_present("clientConnectionNumber", signal["clientConnectionNumber"])
      |> put_if_present("referenceSequenceNumber", signal["referenceSequenceNumber"])
      |> put_if_present("targetClientId", signal["targetClientId"])

    # Determine recipients via Gleam
    recipients = Bridge.determine_signal_recipients(sender_client_id, signal, all_client_ids)

    {message, recipients}
  end

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)
end
