defmodule Levee.Protocol.Bridge do
  @moduledoc """
  Elixir bridge to Gleam protocol modules.

  Provides idiomatic Elixir wrappers around the Gleam functions for sequence
  number management and protocol validation. Sequence-state management (still
  keyed off `levee_protocol`'s vendored `SequenceState`, threaded as opaque
  state through `Levee.Documents.Session`) and JWT claim validation stay on
  `levee_protocol` for now; nack construction, session decision logic
  (feature/version negotiation, signal recipients, wire builders, history
  trimming), and signal v1/v2 normalization delegate to `Levee.Sluice`
  (`sluice/nack`, `sluice/session_logic`, `sluice/signals`, built on
  `spillway`) instead of duplicating that logic in `levee_protocol`.

  The Gleam modules compile to BEAM bytecode, so we can call
  them directly using the Erlang module naming convention.
  """

  # Gleam modules compile to :module_name atoms
  # Note: Gleam submodules use @ separator (e.g., :levee_protocol@sequencing)
  @gleam_module :levee_protocol
  @gleam_sequencing :levee_protocol@sequencing

  # Gleam modules are built separately and not visible to the Elixir compiler.
  # This directive tells the compiler these modules will exist at runtime.
  @compile {:no_warn_undefined,
            [
              :levee_protocol,
              :levee_protocol@sequencing
            ]}

  @doc """
  Create a new sequence state for a document.
  """
  def new_sequence_state do
    @gleam_module.new_sequence_state()
  end

  @doc """
  Create sequence state from a checkpoint.
  """
  def sequence_state_from_checkpoint(sn, msn) do
    @gleam_module.sequence_state_from_checkpoint(sn, msn)
  end

  @doc """
  Register a client joining the session.
  """
  def client_join(state, client_id, join_rsn) do
    @gleam_module.client_join(state, client_id, join_rsn)
  end

  @doc """
  Remove a client from the session.
  """
  def client_leave(state, client_id) do
    @gleam_module.client_leave(state, client_id)
  end

  @doc """
  Assign a sequence number to an operation.

  Returns:
  - `{:ok, new_state, assigned_sn, msn}` on success
  - `{:error, reason}` on failure
  """
  def assign_sequence_number(state, client_id, csn, rsn) do
    case @gleam_module.assign_sequence_number(state, client_id, csn, rsn) do
      # Gleam returns a tagged tuple for the result type
      {:sequence_ok, new_state, assigned_sn, msn} ->
        {:ok, new_state, assigned_sn, msn}

      {:sequence_error, {:invalid_csn, expected, received}} ->
        {:error, {:invalid_csn, expected, received}}

      {:sequence_error, {:invalid_rsn, current_sn, received_rsn}} ->
        {:error, {:invalid_rsn, current_sn, received_rsn}}

      {:sequence_error, {:unknown_client, client_id}} ->
        {:error, {:unknown_client, client_id}}

      other ->
        # Handle any unexpected format
        {:error, {:unexpected_result, other}}
    end
  end

  @doc """
  Get the current sequence number.
  """
  def current_sn(state) do
    @gleam_module.current_sn(state)
  end

  @doc """
  Get the current minimum sequence number.
  """
  def current_msn(state) do
    @gleam_module.current_msn(state)
  end

  @doc """
  Get the count of connected clients.
  """
  def client_count(state) do
    @gleam_module.client_count(state)
  end

  @doc """
  Check if a client is connected.
  """
  def is_client_connected?(state, client_id) do
    @gleam_module.is_client_connected(state, client_id)
  end

  @doc """
  Get list of connected client IDs.
  """
  def connected_clients(state) do
    @gleam_module.connected_clients(state)
  end

  @doc """
  Get write mode constant.
  """
  def write_mode do
    @gleam_module.write_mode()
  end

  @doc """
  Get read mode constant.
  """
  def read_mode do
    @gleam_module.read_mode()
  end

  @doc """
  Update a client's RSN without submitting an op (e.g., from NoOp).
  """
  def update_client_rsn(state, client_id, new_rsn) do
    @gleam_sequencing.update_client_rsn(state, client_id, new_rsn)
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Nack generation helpers
  #
  # Nack construction delegates to Levee.Sluice (sluice/nack.gleam, built on
  # spillway/nack) rather than levee_protocol's vendored copy of the same
  # logic.
  # ─────────────────────────────────────────────────────────────────────────────

  @doc """
  Build a nack for an unknown client error.
  """
  def build_nack_unknown_client(client_id) do
    Levee.Sluice.nack_unknown_client(client_id) |> nack_to_wire_map()
  end

  @doc """
  Build a nack for a read-only client trying to write.
  """
  def build_nack_read_only do
    Levee.Sluice.nack_read_only_client() |> nack_to_wire_map()
  end

  @doc """
  Build a nack from a sequence error reason and the original op.
  Maps Gleam sequence errors to the corresponding nack constructors.
  """
  def build_nack_from_reason(op, reason) do
    nack =
      case reason do
        {:invalid_csn, expected, received} ->
          Levee.Sluice.nack_invalid_csn(expected, received)

        {:invalid_rsn, current_sn, received_rsn} ->
          Levee.Sluice.nack_invalid_rsn(current_sn, received_rsn)

        {:unknown_client, client_id} ->
          Levee.Sluice.nack_unknown_client(client_id)

        {:invalid_summarize, msg} ->
          Levee.Sluice.nack_bad_request("Invalid summarize op: #{msg}")

        _ ->
          Levee.Sluice.nack_bad_request("Sequencing error: #{inspect(reason)}")
      end

    # The nack wire map uses nil for operation, but we want to include the original op
    nack_to_wire_map(nack, op)
  end

  # Convert a Gleam Nack tuple to the wire format map
  defp nack_to_wire_map(nack, op \\ nil) do
    {:nack, _operation, seq_num, {:nack_content, code, error_type, message, retry_after}} = nack

    content = %{
      "code" => code,
      "type" => Levee.Sluice.nack_error_type_to_string(error_type),
      "message" => message
    }

    content =
      case retry_after do
        {:some, seconds} -> Map.put(content, "retryAfter", seconds)
        :none -> content
      end

    %{
      "operation" => op,
      "sequenceNumber" => seq_num,
      "content" => content
    }
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Message type helpers
  # ─────────────────────────────────────────────────────────────────────────────

  @doc """
  Convert message type atom to string.
  """
  def message_type_to_string(type) do
    @gleam_module.message_type_to_string(type)
  end

  @doc """
  Parse message type from string.
  """
  def message_type_from_string(str) do
    @gleam_module.message_type_from_string(str)
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Validation helpers
  # ─────────────────────────────────────────────────────────────────────────────

  @doc """
  Validate message size against limit.
  """
  def validate_message_size(message_bytes, max_size) do
    @gleam_module.validate_message_size(message_bytes, max_size)
  end

  @doc """
  Validate client is in write mode.
  """
  def validate_write_mode(mode) do
    @gleam_module.validate_write_mode(mode)
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Session logic helpers
  #
  # Delegates to Levee.Sluice (sluice/session_logic.gleam, built on
  # spillway/session_logic) rather than levee_protocol's vendored copy of the
  # same logic.
  # ─────────────────────────────────────────────────────────────────────────────

  @doc """
  Negotiate features between server and client capabilities.
  """
  def negotiate_features(server_features, client_features) when is_map(client_features) do
    Levee.Sluice.negotiate_features(server_features, client_features)
  end

  def negotiate_features(server_features, _), do: server_features

  @doc """
  Negotiate protocol version.
  """
  def negotiate_version(supported_versions, client_versions) when is_list(client_versions) do
    Levee.Sluice.negotiate_version(supported_versions, client_versions)
  end

  def negotiate_version(_supported_versions, _), do: "0.1.0"

  @doc """
  Validate summarize operation contents.
  """
  def validate_summarize_contents(contents) when is_map(contents) do
    Levee.Sluice.validate_summarize_contents(contents)
  end

  @doc """
  Determine signal recipients based on targeting rules.
  """
  def determine_signal_recipients(sender_client_id, signal, all_client_ids) do
    targeted = validated(signal["targetedClients"], &is_list/1)
    ignored = validated(signal["ignoredClients"], &is_list/1)
    single_target = validated(signal["targetClientId"], &is_binary/1)

    Levee.Sluice.determine_signal_recipients(
      sender_client_id,
      targeted,
      ignored,
      single_target,
      all_client_ids
    )
  end

  @doc """
  Build a sequenced operation for the wire format.
  """
  def build_sequenced_op(op, client_id, sn, msn) do
    params =
      {:sequenced_op_params, client_id, sn, msn, op["clientSequenceNumber"] || 0,
       op["referenceSequenceNumber"] || 0, op["type"] || "op", op["contents"], op["metadata"],
       System.system_time(:millisecond)}

    Levee.Sluice.build_sequenced_op(params)
  end

  @doc """
  Build a summary ack for the wire format.
  """
  def build_summary_ack(handle, sn, msn) do
    Levee.Sluice.build_summary_ack(handle, sn, msn, System.system_time(:millisecond))
  end

  @doc """
  Add an operation to history (newest first) and trim to max size.
  """
  def add_to_history(op, history, max_size) do
    Levee.Sluice.add_to_history(op, history, max_size)
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Signal normalization helpers
  #
  # Delegates to Levee.Sluice (sluice/signals.gleam, built on
  # spillway/signals) rather than levee_protocol's vendored copy of the same
  # logic.
  # ─────────────────────────────────────────────────────────────────────────────

  @doc """
  Normalize a signal map (v1 or v2) to a consistent internal format.
  Returns an Elixir map with consistent keys.
  """
  def normalize_signal(signal) when is_map(signal) do
    Levee.Sluice.normalize_signal(signal)
  end

  @doc """
  Normalize a batch of signals. Handles lists, single maps.
  """
  def normalize_signal_batch(batch) when is_list(batch) do
    Enum.map(batch, fn
      signal when is_map(signal) ->
        normalize_signal(signal)

      signal when is_binary(signal) ->
        case Jason.decode(signal) do
          {:ok, decoded} -> normalize_signal(decoded)
          {:error, _} -> %{"content" => signal, "type" => nil}
        end

      _ ->
        %{"content" => nil, "type" => nil}
    end)
  end

  def normalize_signal_batch(signal) when is_map(signal), do: [normalize_signal(signal)]

  def normalize_signal_batch(signal) when is_binary(signal) do
    case Jason.decode(signal) do
      {:ok, decoded} when is_map(decoded) -> [normalize_signal(decoded)]
      {:ok, decoded} when is_list(decoded) -> normalize_signal_batch(decoded)
      _ -> []
    end
  end

  def normalize_signal_batch(_), do: []

  # ─────────────────────────────────────────────────────────────────────────────
  # JWT validation helpers
  # ─────────────────────────────────────────────────────────────────────────────

  @doc """
  Convert Elixir JWT claims map to Gleam TokenClaims tuple.
  """
  def elixir_claims_to_gleam(claims) do
    user = {:user, claims.user.id, %{}}

    jti =
      case Map.get(claims, :jti) do
        nil -> :none
        id -> {:some, id}
      end

    {:token_claims, claims.documentId, claims.scopes, claims.tenantId, user, claims.iat,
     claims.exp, Map.get(claims, :ver, "1.0"), jti}
  end

  @doc """
  Validate claims expiration using Gleam JWT module.
  """
  def validate_claims_expiration(claims) do
    gleam_claims = elixir_claims_to_gleam(claims)
    current_time = System.system_time(:second)

    case @gleam_module.jwt_validate_expiration(gleam_claims, current_time) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, :token_expired}
    end
  end

  @doc """
  Validate claims tenant matches request tenant using Gleam JWT module.
  """
  def validate_claims_tenant(claims, tenant_id) do
    gleam_claims = elixir_claims_to_gleam(claims)

    case @gleam_module.jwt_validate_tenant(gleam_claims, tenant_id) do
      {:ok, _} ->
        :ok

      {:error, _} ->
        {:error, {:tenant_mismatch, claims.tenantId, tenant_id}}
    end
  end

  @doc """
  Validate claims document matches request document using Gleam JWT module.
  """
  def validate_claims_document(claims, document_id) do
    gleam_claims = elixir_claims_to_gleam(claims)

    case @gleam_module.jwt_validate_document(gleam_claims, document_id) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, {:document_mismatch, claims.documentId, document_id}}
    end
  end

  @doc """
  Validate claims have the required scopes using Gleam JWT module.
  """
  def validate_claims_scopes(claims, required_scopes) do
    gleam_claims = elixir_claims_to_gleam(claims)

    missing =
      Enum.reject(required_scopes, fn scope ->
        @gleam_module.jwt_has_scope(gleam_claims, scope)
      end)

    case missing do
      [] -> :ok
      _ -> {:error, {:missing_scopes, missing}}
    end
  end

  # Validate a signal targeting field's shape, returning nil (rather than a
  # malformed value) when absent/empty/wrong-typed. Levee.Sluice wraps the
  # nil-or-value result into a Gleam Option for spillway's targeting logic.
  defp validated(nil, _check_fn), do: nil
  defp validated([], _check_fn), do: nil
  defp validated("", _check_fn), do: nil

  defp validated(value, check_fn) do
    if check_fn.(value), do: value, else: nil
  end
end
