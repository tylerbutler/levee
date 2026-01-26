defmodule FluidServer.Protocol.Bridge do
  @moduledoc """
  Elixir bridge to Gleam protocol module.

  Provides idiomatic Elixir wrappers around the Gleam functions
  for sequence number management and protocol validation.

  The Gleam module compiles to BEAM bytecode, so we can call
  it directly using the Erlang module naming convention.
  """

  # Gleam modules compile to :module_name atoms
  @gleam_module :fluid_protocol

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
end
