defmodule LeveeWeb.DeltaController do
  @moduledoc """
  Controller for Fluid Framework delta (operation history) retrieval.

  Implements the Storage Service HTTP API:
  - GET /deltas/:tenant_id/:id - Get operations with pagination

  Storage calls and Plug/Conn handling stay here; the wire *shape* for each
  sequenced message (field names, and whether a JSON-stringified `data`
  sidecar is attached for join/leave system messages) is delegated to
  Floodgate's `floodgate/rest` module via `Levee.Floodgate`.
  """

  use LeveeWeb, :controller

  alias Levee.Storage
  alias Levee.Floodgate
  require Logger

  @max_ops_per_request 2000

  @doc """
  Get sequenced operations (deltas) for a document.

  GET /deltas/:tenant_id/:id

  Query parameters:
  - from: Exclusive lower bound on sequence number
  - to: Inclusive upper bound on sequence number

  Behavior:
  - If neither from nor to specified: Returns first 2000 ops from sequence 0
  - If only from specified: Returns up to 2000 ops after from
  - If only to specified: Returns up to 2000 ops before to
  - Maximum ops per request: 2000
  """
  def index(conn, %{"tenant_id" => tenant_id, "id" => document_id} = params) do
    # Parse query parameters
    from_sn = parse_int_param(params["from"], -1)
    to_sn = parse_int_param(params["to"], nil)

    opts = [
      from: from_sn,
      to: to_sn,
      limit: @max_ops_per_request
    ]

    {:ok, deltas} = Storage.get_deltas(tenant_id, document_id, opts)

    Logger.info(
      "GET /deltas/#{tenant_id}/#{document_id} from=#{inspect(from_sn)} to=#{inspect(to_sn)} => #{length(deltas)} deltas"
    )

    # Convert deltas to the ISequencedDocumentMessage format
    messages = Enum.map(deltas, &format_sequenced_message/1)

    conn
    |> put_status(:ok)
    |> json(%{value: messages})
  end

  # Private functions

  defp parse_int_param(nil, default), do: default

  defp parse_int_param(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> default
    end
  end

  defp parse_int_param(value, _default) when is_integer(value), do: value

  defp format_sequenced_message(delta) do
    data =
      if Floodgate.requires_data_field?(delta.type) do
        Jason.encode!(delta.contents)
      end

    Floodgate.format_delta_message(
      delta.sequence_number,
      delta.client_sequence_number,
      delta.minimum_sequence_number,
      delta.client_id,
      delta.reference_sequence_number,
      delta.type,
      delta.contents,
      delta.metadata,
      delta.timestamp,
      data
    )
  end
end
