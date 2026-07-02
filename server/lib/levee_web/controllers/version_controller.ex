defmodule LeveeWeb.VersionController do
  @moduledoc """
  Controller for summary version listing (the client `getVersions` call).

  Implements the Storage Service HTTP API:
  - GET /versions/:tenant_id/:id - List summary versions, newest first
  """

  use LeveeWeb, :controller

  alias Levee.Storage
  require Logger

  @max_versions_per_request 100

  @doc """
  List summary versions for a document, newest first.

  GET /versions/:tenant_id/:id

  Query parameters:
  - count: Maximum number of versions to return (default 10, capped at 100)

  Every summarize op stores a summary record, so the newest version is the
  one a fresh connection bootstraps from; older entries allow historical
  snapshot reads by handle.
  """
  def index(conn, %{"tenant_id" => tenant_id, "id" => document_id} = params) do
    count =
      params["count"]
      |> parse_int_param(10)
      |> min(@max_versions_per_request)
      |> max(0)

    # Summaries are rare relative to deltas, so fetch the full ascending list
    # and keep the newest `count`.
    {:ok, summaries} =
      Storage.list_summaries(tenant_id, document_id,
        from_sequence_number: 0,
        limit: 1_000_000
      )

    versions =
      summaries
      |> Enum.take(-count)
      |> Enum.reverse()
      |> Enum.map(&format_version/1)

    Logger.info(
      "GET /versions/#{tenant_id}/#{document_id} count=#{count} => #{length(versions)} versions"
    )

    conn
    |> put_status(:ok)
    |> json(%{value: versions})
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

  defp format_version(summary) do
    %{
      handle: summary.handle,
      sequenceNumber: summary.sequence_number,
      treeSha: summary.tree_sha,
      parentHandle: summary.parent_handle,
      message: summary.message,
      createdAt: summary.created_at
    }
  end
end
