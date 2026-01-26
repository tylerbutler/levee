defmodule Levee.Protocol.Bridge do
  @moduledoc """
  Elixir bridge to Gleam protocol module.

  Provides idiomatic Elixir wrappers around the Gleam functions
  for sequence number management, nack generation, and protocol validation.

  The Gleam module compiles to BEAM bytecode, so we can call
  it directly using the Erlang module naming convention.
  """

  # Gleam modules compile to :module_name atoms
  # Note: Gleam submodules use @ separator (e.g., :levee_protocol@sequencing)
  @gleam_module :levee_protocol
  @gleam_sequencing :levee_protocol@sequencing

  # Gleam modules are built separately and not visible to the Elixir compiler.
  # This directive tells the compiler these modules will exist at runtime.
  @compile {:no_warn_undefined, [:levee_protocol, :levee_protocol@sequencing]}

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
    case @gleam_sequencing.update_client_rsn(state, client_id, new_rsn) do
      {:ok, new_state} ->
        {:ok, new_state}

      {:error, {:unknown_client, cid}} ->
        {:error, {:unknown_client, cid}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Nack generation helpers
  # ─────────────────────────────────────────────────────────────────────────────

  @doc """
  Build a nack for an unknown client error.
  """
  def build_nack_unknown_client(client_id) do
    %{
      "operation" => nil,
      "sequenceNumber" => -1,
      "content" => %{
        "code" => 400,
        "type" => "BadRequestError",
        "message" => "Unknown client: #{client_id}"
      }
    }
  end

  @doc """
  Build a nack for a read-only client trying to write.
  """
  def build_nack_read_only do
    %{
      "operation" => nil,
      "sequenceNumber" => -1,
      "content" => %{
        "code" => 400,
        "type" => "BadRequestError",
        "message" => "Client is in read-only mode"
      }
    }
  end

  @doc """
  Build a nack for invalid CSN.
  """
  def build_nack_invalid_csn(expected, received, op) do
    %{
      "operation" => op,
      "sequenceNumber" => -1,
      "content" => %{
        "code" => 400,
        "type" => "BadRequestError",
        "message" => "Invalid CSN: expected > #{expected}, received #{received}"
      }
    }
  end

  @doc """
  Build a nack for invalid RSN.
  """
  def build_nack_invalid_rsn(current_sn, received_rsn, op) do
    %{
      "operation" => op,
      "sequenceNumber" => -1,
      "content" => %{
        "code" => 400,
        "type" => "BadRequestError",
        "message" => "Invalid RSN: current SN is #{current_sn}, received #{received_rsn}"
      }
    }
  end

  @doc """
  Build a nack for throttling (rate limit exceeded).
  """
  def build_nack_throttled(retry_after_seconds) do
    %{
      "operation" => nil,
      "sequenceNumber" => -1,
      "content" => %{
        "code" => 429,
        "type" => "ThrottlingError",
        "message" => "Rate limit exceeded",
        "retryAfter" => retry_after_seconds
      }
    }
  end

  @doc """
  Build a nack for message too large.
  """
  def build_nack_message_too_large(max_size, actual_size, op) do
    %{
      "operation" => op,
      "sequenceNumber" => -1,
      "content" => %{
        "code" => 413,
        "type" => "BadRequestError",
        "message" => "Message size #{actual_size} exceeds limit #{max_size}"
      }
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
end
