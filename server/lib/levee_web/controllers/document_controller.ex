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
  List all documents for a tenant.

  GET /documents/:tenant_id
  """
  def index(conn, %{"tenant_id" => tenant_id}) do
    case Storage.list_documents(tenant_id) do
      {:ok, docs} ->
        documents =
          Enum.map(docs, fn doc ->
            session_alive =
              case Registry.get_session(tenant_id, doc.id) do
                {:ok, _pid} -> true
                _ -> false
              end

            %{
              id: doc.id,
              tenantId: doc.tenant_id,
              sequenceNumber: doc.sequence_number,
              appName: doc.app_name,
              appVersion: doc.app_version,
              sessionAlive: session_alive
            }
          end)

        json(conn, %{documents: documents})

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: inspect(reason)})
    end
  end

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

    create_params = %{
      sequence_number: sequence_number,
      app_name: params["appName"],
      app_version: params["appVersion"]
    }

    case Storage.create_document(tenant_id, document_id, create_params) do
      {:ok, _document} ->
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
    host = LeveeWeb.Endpoint.url()
    is_alive = match?({:ok, _pid}, Registry.get_session(tenant_id, document_id))

    %{
      ordererUrl: "#{host}/socket",
      historianUrl: "#{host}/repos/#{tenant_id}",
      deltaStreamUrl: "#{host}/deltas/#{tenant_id}/#{document_id}",
      isSessionAlive: is_alive,
      isSessionActive: is_alive
    }
  end

  # Process the initial summary from container attach by building a full
  # git object graph (blobs → trees → commit → ref). This allows other
  # clients to load the container via getVersions() → getSnapshotTree().
  #
  # The Fluid client sends a combined summary with ".app" and ".protocol"
  # as top-level keys. The server must unwrap ".app" so its contents
  # (e.g., .channels, .aliases, .metadata) sit at the root of the stored
  # snapshot tree alongside ".protocol". This matches what the container
  # runtime expects when loading: .channels at root, .protocol as sibling.
  defp process_initial_summary(tenant_id, document_id, %{"type" => 1, "tree" => tree}) do
    app_summary = tree[".app"]
    protocol_summary = tree[".protocol"]

    if app_summary == nil do
      :ok
    else
      # Build git objects for each child of .app (not .app itself)
      app_entries =
        case app_summary do
          %{"type" => 1, "tree" => app_tree} ->
            Enum.map(app_tree, fn {path, node} ->
              {:ok, sha, type} = build_summary_objects(tenant_id, node)
              mode = if type == "tree", do: "040000", else: "100644"
              %{path: path, sha: sha, mode: mode, type: type}
            end)

          _ ->
            []
        end

      # Build git objects for .protocol and add as a sibling
      protocol_entries =
        case protocol_summary do
          %{"type" => 1, "tree" => _} ->
            {:ok, sha, _type} = build_summary_objects(tenant_id, protocol_summary)
            [%{path: ".protocol", sha: sha, mode: "040000", type: "tree"}]

          _ ->
            []
        end

      entries = app_entries ++ protocol_entries
      {:ok, root_tree} = Storage.create_tree(tenant_id, entries)

      now = DateTime.utc_now() |> DateTime.to_iso8601()

      {:ok, commit} =
        Storage.create_commit(tenant_id, %{
          "tree" => root_tree.sha,
          "parents" => [],
          "message" => "Initial summary",
          "author" => %{"name" => "Levee", "email" => "server@levee.local", "date" => now}
        })

      Storage.create_ref(tenant_id, "refs/heads/#{document_id}", commit.sha)
      {:ok, commit.sha}
    end
  end

  defp process_initial_summary(_tenant_id, _document_id, _summary), do: :ok

  # Recursively walk the Fluid summary tree, storing blobs and building
  # tree objects bottom-up. Returns {:ok, sha, type} for each node.
  defp build_summary_objects(tenant_id, %{"type" => 1, "tree" => tree}) do
    # Type 1 = SummaryTree: process children, then create tree from entries
    entries =
      Enum.map(tree, fn {path, node} ->
        {:ok, sha, type} = build_summary_objects(tenant_id, node)
        mode = if type == "tree", do: "040000", else: "100644"
        %{path: path, sha: sha, mode: mode, type: type}
      end)

    {:ok, tree_obj} = Storage.create_tree(tenant_id, entries)
    {:ok, tree_obj.sha, "tree"}
  end

  defp build_summary_objects(tenant_id, %{"type" => 2, "content" => content}) do
    # Type 2 = SummaryBlob: store blob content, return its SHA
    binary_content =
      if is_binary(content) do
        content
      else
        Jason.encode!(content)
      end

    {:ok, blob} = Storage.create_blob(tenant_id, binary_content)
    {:ok, blob.sha, "blob"}
  end

  defp build_summary_objects(_tenant_id, _), do: {:ok, "", "blob"}
end
