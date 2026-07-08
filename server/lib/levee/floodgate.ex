defmodule Levee.Floodgate do
  @moduledoc """
  Elixir bridge to Floodgate's Gleam-owned Engine.IO/Socket.IO framing and
  `connect_document` protocol decision helpers.

  Floodgate (`server/floodgate/`) owns the Fluid Socket.IO wire-protocol pieces
  that don't need Levee's tenant-secret storage or document Session/Registry
  runtime: Engine.IO/Socket.IO frame classification and encoding (delegating
  to `windsock`/`dewdrop` for the actual protocol vocabulary and framing
  constants), the `connect_document` payload-shape and mode/scope decisions,
  and the pure document-session decision logic (feature/version negotiation,
  signal v1/v2 normalization and recipient targeting, sequenced-op/
  summary-ack wire builders, nack construction, op-history trimming) — all
  built on `spillway` rather than Levee's vendored `levee_protocol` copy of
  the same logic, so the two don't drift. Levee still owns JWT verification
  (tenant secrets) and the document Session/Registry runtime (connected
  client PIDs, storage, op history storage); it calls through this module
  for the protocol decisions so `LeveeWeb.SocketIOWebSock` and
  `Levee.Documents.Session` stay thin over the actual Fluid protocol logic.

  It also owns the REST response-*shape* decisions (`floodgate/rest`) for the
  Storage/Historian-style HTTP surface: git object/ref URL construction and
  blob/tree/commit/ref response bodies, `GET .../session/:id` session-info
  shape, `GET .../:id` document metadata shape, and the `GET /deltas/...`
  sequenced-message shape (including the join/leave `data`-field decision).
  `LeveeWeb.GitController`, `LeveeWeb.DocumentController`, and
  `LeveeWeb.DeltaController` still own the actual storage calls, Plug/Conn
  handling, and JSON encoding — they call through this module to decide the
  response body shape so the wire format lives in one (Floodgate-owned) place.

  Floodgate's compiled Gleam modules are loaded onto the code path by
  `Levee.Application.load_gleam_modules/0` alongside the other Gleam
  packages, so these are ordinary BEAM calls once compiled — no ports,
  NIFs, or RPC involved. Calls go through `apply/3` (rather than a direct
  module alias) because the Gleam build is a separate compilation step from
  `mix compile`; see `AGENTS.md`/the gleam-bridge guide for the build order.
  """

  @socketio :floodgate@socketio
  @connect_document :floodgate@connect_document
  @session_logic :floodgate@session_logic
  @signals :floodgate@signals
  @nack :floodgate@nack
  @rest :floodgate@rest

  # ── Engine.IO / Socket.IO framing ──────────────────────────────────────

  @doc "Encode the Engine.IO opening handshake packet."
  @spec encode_open(String.t(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          String.t()
  def encode_open(sid, ping_interval_ms, ping_timeout_ms, max_payload) do
    apply(@socketio, :encode_open, [sid, ping_interval_ms, ping_timeout_ms, max_payload])
  end

  @doc "Encode the Socket.IO namespace-connect ack."
  @spec encode_connect_ack(String.t()) :: String.t()
  def encode_connect_ack(sid) do
    apply(@socketio, :encode_connect_ack, [sid])
  end

  @doc "Encode an Engine.IO pong reply."
  @spec encode_pong() :: String.t()
  def encode_pong do
    apply(@socketio, :encode_pong, [])
  end

  @doc """
  Classify a raw inbound Engine.IO/Socket.IO text frame.

  Returns one of:
  - `:engine_ping` / `:engine_pong`
  - `:socket_connect`
  - `{:fluid_event, event, args}`
  - `{:unrecognized, reason}`
  """
  @spec classify_frame(String.t()) ::
          :engine_ping
          | :engine_pong
          | :socket_connect
          | {:fluid_event, String.t(), list()}
          | {:unrecognized, String.t()}
  def classify_frame(text) do
    apply(@socketio, :classify, [text])
  end

  @doc "Encode a sequenced-ops fan-out frame: `op(documentId, messages)`."
  @spec encode_op(term(), term()) :: String.t()
  def encode_op(document_id, messages) do
    apply(@socketio, :encode_op, [to_gleam_json(document_id), to_gleam_json(messages)])
  end

  @doc "Encode a signal fan-out frame: `signal(signalMessage)`."
  @spec encode_signal(term()) :: String.t()
  def encode_signal(signal_message) do
    apply(@socketio, :encode_signal, [to_gleam_json(signal_message)])
  end

  @doc "Encode a `connect_document_success` reply."
  @spec encode_connect_document_success(map()) :: String.t()
  def encode_connect_document_success(payload) do
    apply(@socketio, :encode_connect_document_success, [to_gleam_json(payload)])
  end

  @doc "Encode a `connect_document_error` reply."
  @spec encode_connect_document_error(map()) :: String.t()
  def encode_connect_document_error(payload) do
    apply(@socketio, :encode_connect_document_error, [to_gleam_json(payload)])
  end

  # ── connect_document protocol decisions ────────────────────────────────

  @doc """
  Extract the tenant/document/token fields a `connect_document` payload must
  carry.

  Returns `{:ok, {tenant_id, document_id, token}}` or
  `{:error, {:missing_field, field}}`.
  """
  @spec parse_connect_request(map()) ::
          {:ok, {String.t(), String.t(), String.t()}} | {:error, {:missing_field, String.t()}}
  def parse_connect_request(payload) when is_map(payload) do
    case apply(@connect_document, :parse_request, [payload]) do
      {:ok, {:connect_request, tenant_id, document_id, token}} ->
        {:ok, {tenant_id, document_id, token}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Validate that a `connect_document` payload requesting write mode has the
  `doc:write` scope in `scopes`. Any other (or absent) mode always passes.
  """
  @spec validate_mode_scope(map(), [String.t()]) :: :ok | {:error, atom()}
  def validate_mode_scope(payload, scopes) when is_map(payload) and is_list(scopes) do
    case apply(@connect_document, :validate_mode_scope, [payload, scopes]) do
      {:ok, nil} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "The `doc:read` scope string, from spillway's `Scope` vocabulary."
  @spec read_scope() :: String.t()
  def read_scope, do: apply(@connect_document, :read_scope, [])

  @doc "The `doc:write` scope string, from spillway's `Scope` vocabulary."
  @spec write_scope() :: String.t()
  def write_scope, do: apply(@connect_document, :write_scope, [])

  # ── Document-session decision logic (spillway/session_logic) ──────────

  @doc """
  Negotiate features between server and client capabilities.

  Server-supported features win unless the client explicitly declines
  (`false`); client silence advertises the server's value.
  """
  @spec negotiate_features(%{String.t() => boolean()}, %{String.t() => boolean()}) ::
          %{String.t() => boolean()}
  def negotiate_features(server_features, client_features)
      when is_map(server_features) and is_map(client_features) do
    apply(@session_logic, :negotiate_features, [server_features, client_features])
  end

  @doc """
  Negotiate the protocol version from the client's supported version
  ranges, falling back to `"0.1.0"` if nothing matches.
  """
  @spec negotiate_version([String.t()], [String.t()]) :: String.t()
  def negotiate_version(supported_versions, client_versions)
      when is_list(supported_versions) and is_list(client_versions) do
    apply(@session_logic, :negotiate_version, [supported_versions, client_versions])
  end

  @doc """
  Validate that summarize operation contents have the required fields
  (`handle`, `message`, `parents`, `head`).
  """
  @spec validate_summarize_contents(map()) :: :ok | {:error, String.t()}
  def validate_summarize_contents(contents) when is_map(contents) do
    case apply(@session_logic, :validate_summarize_contents, [contents]) do
      {:ok, nil} -> :ok
      {:error, msg} -> {:error, msg}
    end
  end

  @doc """
  Determine which clients should receive a signal, given the v1/v2
  targeting rules. Priority: `targeted_clients` > `ignored_clients` >
  `single_target` > broadcast-to-all-except-sender.

  Each of `targeted_clients`, `ignored_clients`, and `single_target` should
  be `nil` or the respective value (list of client ids, or a single client
  id) — this function wraps them into Gleam `Option`s.
  """
  @spec determine_signal_recipients(
          String.t(),
          [String.t()] | nil,
          [String.t()] | nil,
          String.t() | nil,
          [String.t()]
        ) :: [String.t()]
  def determine_signal_recipients(
        sender_client_id,
        targeted_clients,
        ignored_clients,
        single_target,
        all_client_ids
      ) do
    apply(@session_logic, :determine_signal_recipients, [
      sender_client_id,
      wrap_option(targeted_clients),
      wrap_option(ignored_clients),
      wrap_option(single_target),
      all_client_ids
    ])
  end

  @doc """
  Build a sequenced operation for the wire format.

  `params` is the raw `{:sequenced_op_params, client_id, sn, msn, csn, rsn,
  type, contents, metadata, timestamp}` tuple matching spillway's
  `SequencedOpParams` record shape.
  """
  @spec build_sequenced_op(tuple()) :: map()
  def build_sequenced_op(params) when is_tuple(params) do
    apply(@session_logic, :build_sequenced_op, [params]) |> Map.new()
  end

  @doc "Build a summary ack for the wire format."
  @spec build_summary_ack(String.t(), integer(), integer(), integer()) :: map()
  def build_summary_ack(handle, sn, msn, timestamp) do
    apply(@session_logic, :build_summary_ack, [handle, sn, msn, timestamp]) |> Map.new()
  end

  @doc """
  Add an operation to a document's op history (newest first) and trim to
  `max_size` — the delta catch-up history levee's Session keeps for
  `requestOps`/`get_ops_since`.
  """
  @spec add_to_history(term(), [term()], non_neg_integer()) :: [term()]
  def add_to_history(op, history, max_size) when is_list(history) do
    apply(@session_logic, :add_to_history, [op, history, max_size])
  end

  # ── Signal v1/v2 normalization (spillway/signals) ──────────────────────

  @doc """
  Normalize a raw signal map (v1 or v2) to a consistent internal format.
  Returns a plain Elixir map with consistent keys (`content`, `type`,
  `clientConnectionNumber`, `referenceSequenceNumber`, `targetClientId`,
  `targetedClients`, `ignoredClients`).
  """
  @spec normalize_signal(map()) :: map()
  def normalize_signal(signal) when is_map(signal) do
    normalized = apply(@signals, :normalize_signal, [signal])
    apply(@signals, :normalized_to_map, [normalized])
  end

  # ── Nack construction (spillway/nack) ──────────────────────────────────

  @doc "Build a nack for an unknown client."
  @spec nack_unknown_client(String.t()) :: tuple()
  def nack_unknown_client(client_id), do: apply(@nack, :unknown_client, [client_id])

  @doc "Build a nack for a read-only client attempting to write."
  @spec nack_read_only_client() :: tuple()
  def nack_read_only_client, do: apply(@nack, :read_only_client, [:none])

  @doc "Build a nack for an invalid client sequence number."
  @spec nack_invalid_csn(integer(), integer()) :: tuple()
  def nack_invalid_csn(expected, received) do
    apply(@nack, :invalid_csn, [expected, received, :none])
  end

  @doc "Build a nack for an invalid reference sequence number."
  @spec nack_invalid_rsn(integer(), integer()) :: tuple()
  def nack_invalid_rsn(current_sn, received_rsn) do
    apply(@nack, :invalid_rsn, [current_sn, received_rsn, :none])
  end

  @doc "Build a nack for a malformed/invalid request."
  @spec nack_bad_request(String.t()) :: tuple()
  def nack_bad_request(message), do: apply(@nack, :bad_request, [message, :none])

  @doc "Convert a nack error type atom to its wire-format string."
  @spec nack_error_type_to_string(atom()) :: String.t()
  def nack_error_type_to_string(error_type) do
    apply(@nack, :nack_error_type_to_string, [error_type])
  end

  # ── REST response-shape decisions (floodgate/rest) ────────────────────────

  @doc """
  Build the `scheme://host[:port]` prefix used by git object/ref URLs,
  omitting the port for the scheme's default (80 for http, 443 for https).
  """
  @spec base_url(String.t(), String.t(), non_neg_integer()) :: String.t()
  def base_url(scheme, host, port) do
    apply(@rest, :base_url, [to_string(scheme), host, port])
  end

  @doc "Build a blob object URL: `\#{base_url}/repos/\#{tenant_id}/git/blobs/\#{sha}`."
  @spec blob_url(String.t(), String.t(), String.t()) :: String.t()
  def blob_url(base_url, tenant_id, sha), do: apply(@rest, :blob_url, [base_url, tenant_id, sha])

  @doc "Build a tree object URL: `\#{base_url}/repos/\#{tenant_id}/git/trees/\#{sha}`."
  @spec tree_url(String.t(), String.t(), String.t()) :: String.t()
  def tree_url(base_url, tenant_id, sha), do: apply(@rest, :tree_url, [base_url, tenant_id, sha])

  @doc "Build a commit object URL: `\#{base_url}/repos/\#{tenant_id}/git/commits/\#{sha}`."
  @spec commit_url(String.t(), String.t(), String.t()) :: String.t()
  def commit_url(base_url, tenant_id, sha) do
    apply(@rest, :commit_url, [base_url, tenant_id, sha])
  end

  @doc """
  Build a ref URL, stripping the `refs/` prefix:
  `\#{base_url}/repos/\#{tenant_id}/git/refs/\#{ref_path_without_refs_prefix}`.
  """
  @spec ref_url(String.t(), String.t(), String.t()) :: String.t()
  def ref_url(base_url, tenant_id, ref_path) do
    apply(@rest, :ref_url, [base_url, tenant_id, ref_path])
  end

  @doc """
  Join wildcard-route ref path segments (from `GET/PATCH .../refs/*ref`)
  into a full `refs/...` path.
  """
  @spec build_ref_path([String.t()]) :: String.t()
  def build_ref_path(ref_parts) when is_list(ref_parts) do
    apply(@rest, :build_ref_path, [ref_parts])
  end

  @doc "Build the `GET /repos/:tenant_id/git/blobs/:sha` response body."
  @spec format_blob_response(String.t(), String.t(), String.t(), non_neg_integer(), String.t()) ::
          map()
  def format_blob_response(base_url, tenant_id, sha, size, content_base64) do
    apply(@rest, :format_blob_response, [base_url, tenant_id, sha, size, content_base64])
    |> Map.new()
  end

  @doc """
  Build the `GET/POST /repos/:tenant_id/git/trees/:sha` response body.

  `entries` is a list of `{path, mode, sha, type}` tuples (`type` is
  `"blob"` or `"tree"`); each formatted entry gets a `url` field built from
  its own type (or `nil` for any other type).
  """
  @spec format_tree_response(String.t(), String.t(), String.t(), [
          {String.t(), String.t(), String.t(), String.t()}
        ]) :: map()
  def format_tree_response(base_url, tenant_id, sha, entries) do
    apply(@rest, :format_tree_response, [base_url, tenant_id, sha, entries])
    |> Map.new()
  end

  @doc "Build the `GET/POST /repos/:tenant_id/git/commits/:sha` response body."
  @spec format_commit_response(
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          [String.t()],
          term(),
          term(),
          term()
        ) :: map()
  def format_commit_response(
        base_url,
        tenant_id,
        sha,
        tree_sha,
        parents,
        message,
        author,
        committer
      ) do
    apply(@rest, :format_commit_response, [
      base_url,
      tenant_id,
      sha,
      tree_sha,
      parents,
      message,
      author,
      committer
    ])
    |> Map.new()
  end

  @doc "Build a `GET/POST/PATCH /repos/:tenant_id/git/refs/*` response body."
  @spec format_ref_response(String.t(), String.t(), String.t(), String.t()) :: map()
  def format_ref_response(base_url, tenant_id, ref_path, sha) do
    apply(@rest, :format_ref_response, [base_url, tenant_id, ref_path, sha]) |> Map.new()
  end

  @doc "Build the `GET /documents/:tenant_id/:id` response body."
  @spec format_document_response(String.t(), String.t(), integer()) :: map()
  def format_document_response(id, tenant_id, sequence_number) do
    apply(@rest, :format_document_response, [id, tenant_id, sequence_number]) |> Map.new()
  end

  @doc "Build the `GET /documents/:tenant_id/session/:id` response body."
  @spec session_info(String.t(), String.t(), String.t(), boolean()) :: map()
  def session_info(host, tenant_id, document_id, is_alive) do
    apply(@rest, :session_info, [host, tenant_id, document_id, is_alive]) |> Map.new()
  end

  @doc """
  Whether a delta message `type` (e.g. `"join"`/`"leave"`) needs a
  JSON-stringified `data` sidecar field alongside `contents` in the
  `GET /deltas/:tenant_id/:id` response.
  """
  @spec requires_data_field?(String.t()) :: boolean()
  def requires_data_field?(msg_type), do: apply(@rest, :requires_data_field, [msg_type])

  @doc """
  Build a single `ISequencedDocumentMessage` for the
  `GET /deltas/:tenant_id/:id` response.

  `data` is only included in the response when `requires_data_field?/1` is
  true for `msg_type`; pass `nil` when it isn't needed.
  """
  @spec format_delta_message(
          integer(),
          integer(),
          integer(),
          term(),
          integer(),
          String.t(),
          term(),
          term(),
          integer(),
          term()
        ) :: map()
  def format_delta_message(
        sequence_number,
        client_sequence_number,
        minimum_sequence_number,
        client_id,
        reference_sequence_number,
        msg_type,
        contents,
        metadata,
        timestamp,
        data
      ) do
    apply(@rest, :format_delta_message, [
      sequence_number,
      client_sequence_number,
      minimum_sequence_number,
      client_id,
      reference_sequence_number,
      msg_type,
      contents,
      metadata,
      timestamp,
      data
    ])
    |> Map.new()
  end

  defp wrap_option(nil), do: :none
  defp wrap_option([]), do: :none
  defp wrap_option(""), do: :none
  defp wrap_option(value), do: {:some, value}

  # ── Elixir → gleam/json conversion ─────────────────────────────────────

  @doc """
  Convert a plain Elixir term (map/list/string/number/bool/nil) into a
  `gleam/json.Json` value so it can be passed to the `encode_*` helpers
  above.
  """
  @spec to_gleam_json(term()) :: term()
  def to_gleam_json(value) when is_binary(value), do: gleam_json(:string, [value])
  def to_gleam_json(value) when is_boolean(value), do: gleam_json(:bool, [value])
  def to_gleam_json(value) when is_integer(value), do: gleam_json(:int, [value])
  def to_gleam_json(value) when is_float(value), do: gleam_json(:float, [value])
  def to_gleam_json(nil), do: gleam_json(:null, [])

  def to_gleam_json(values) when is_list(values) do
    gleam_json(:preprocessed_array, [Enum.map(values, &to_gleam_json/1)])
  end

  def to_gleam_json(value) when is_map(value) do
    value
    |> Enum.map(fn {key, map_value} -> {to_string(key), to_gleam_json(map_value)} end)
    |> then(&gleam_json(:object, [&1]))
  end

  defp gleam_json(function, args), do: apply(:gleam@json, function, args)
end
