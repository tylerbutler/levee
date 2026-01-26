defmodule LeveeWeb.DocumentController do
  @moduledoc """
  Controller for Fluid Framework document operations.

  Implements the Storage Service HTTP API:
  - POST /documents/:tenant_id - Create document
  - GET /documents/:tenant_id/:id - Get document metadata
  - GET /documents/:tenant_id/session/:id - Get session info
  """

  use LeveeWeb, :controller

  alias Levee.Storage
  alias Levee.Documents.Registry

  @doc """
  Create a new document.

  POST /documents/:tenant_id

  Request body:
  - id (optional): Document ID, auto-generated if omitted
  - summary: Initial summary tree
  - sequenceNumber: Initial sequence number (typically 0)
  - values: Initial protocol values
  """
  def create(conn, %{"tenant_id" => tenant_id} = params) do
    document_id = params["id"] || generate_document_id()
    sequence_number = params["sequenceNumber"] || 0

    case Storage.create_document(tenant_id, document_id, %{sequence_number: sequence_number}) do
      {:ok, _document} ->
        # Process initial summary if provided
        if summary = params["summary"] do
          process_initial_summary(tenant_id, document_id, summary)
        end

        # Return the document ID or full session info
        if params["enableDiscovery"] do
          conn
          |> put_status(:created)
          |> json(%{
            id: document_id,
            session: build_session_info(tenant_id, document_id)
          })
        else
          conn
          |> put_status(:created)
          |> json(document_id)
        end

      {:error, :already_exists} ->
        conn
        |> put_status(:conflict)
        |> json(%{error: "Document already exists"})

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: inspect(reason)})
    end
  end

  @doc """
  Get document metadata.

  GET /documents/:tenant_id/:id
  """
  def show(conn, %{"tenant_id" => tenant_id, "id" => document_id}) do
    case Storage.get_document(tenant_id, document_id) do
      {:ok, document} ->
        conn
        |> put_status(:ok)
        |> json(%{
          id: document.id,
          tenantId: document.tenant_id,
          sequenceNumber: document.sequence_number
        })

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Document not found"})
    end
  end

  @doc """
  Get session information for a document.

  GET /documents/:tenant_id/session/:id
  """
  def session(conn, %{"tenant_id" => tenant_id, "id" => document_id}) do
    # Check if document exists
    case Storage.get_document(tenant_id, document_id) do
      {:ok, _document} ->
        session_info = build_session_info(tenant_id, document_id)

        conn
        |> put_status(:ok)
        |> json(session_info)

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Document not found"})
    end
  end

  # Private functions

  defp generate_document_id do
    :crypto.strong_rand_bytes(16)
    |> Base.encode16(case: :lower)
  end

  defp build_session_info(tenant_id, document_id) do
    # Get the endpoint URL from config
    host = LeveeWeb.Endpoint.url()

    # Check if session is alive (has active GenServer)
    is_alive =
      case Registry.get_session(tenant_id, document_id) do
        {:ok, _pid} -> true
        _ -> false
      end

    %{
      ordererUrl: "#{host}/socket",
      historianUrl: "#{host}/repos/#{tenant_id}",
      deltaStreamUrl: "#{host}/deltas/#{tenant_id}/#{document_id}",
      isSessionAlive: is_alive,
      isSessionActive: is_alive
    }
  end

  defp process_initial_summary(tenant_id, _document_id, summary) do
    # Process the summary tree and store blobs/trees
    process_summary_tree(tenant_id, summary)
  end

  defp process_summary_tree(tenant_id, %{"type" => 1, "tree" => tree}) do
    # Type 1 = SummaryTree
    Enum.each(tree, fn {_path, node} ->
      process_summary_node(tenant_id, node)
    end)
  end

  defp process_summary_tree(_tenant_id, _), do: :ok

  defp process_summary_node(tenant_id, %{"type" => 1} = tree) do
    # Nested tree
    process_summary_tree(tenant_id, tree)
  end

  defp process_summary_node(tenant_id, %{"type" => 2, "content" => content}) do
    # Type 2 = SummaryBlob
    binary_content =
      if is_binary(content) do
        content
      else
        Jason.encode!(content)
      end

    Storage.create_blob(tenant_id, binary_content)
  end

  defp process_summary_node(_tenant_id, _), do: :ok
end
