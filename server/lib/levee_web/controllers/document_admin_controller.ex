defmodule LeveeWeb.DocumentAdminController do
  @moduledoc """
  Read-only admin endpoints for inspecting documents, deltas, summaries,
  refs, and git objects within a tenant.
  """

  use LeveeWeb, :controller

  alias Levee.Storage
  alias Levee.Documents.Registry

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

            Map.put(doc, :session_alive, session_alive)
          end)

        json(conn, %{documents: documents})

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: %{code: "storage_error", message: inspect(reason)}})
    end
  end

  def show(conn, %{"tenant_id" => tenant_id, "id" => document_id}) do
    case Storage.get_document(tenant_id, document_id) do
      {:ok, doc} ->
        session_info =
          case Registry.get_session(tenant_id, document_id) do
            {:ok, pid} ->
              case Levee.Documents.Session.get_state_summary(pid) do
                {:ok, summary} -> summary
                _ -> nil
              end

            _ ->
              nil
          end

        json(conn, %{document: doc, session: session_info})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "not_found", message: "Document not found"}})
    end
  end

  def deltas(conn, %{"tenant_id" => tenant_id, "id" => document_id} = params) do
    from = parse_int_param(params, "from", -1)
    to = parse_optional_int_param(params, "to")
    limit = parse_int_param(params, "limit", 100)

    opts = [from: from, limit: limit] ++ if(to, do: [to: to], else: [])

    case Storage.get_deltas(tenant_id, document_id, opts) do
      {:ok, deltas} ->
        json(conn, %{deltas: deltas})
    end
  end

  def summaries(conn, %{"tenant_id" => tenant_id, "id" => document_id} = params) do
    from_sn = parse_int_param(params, "from_sequence_number", 0)
    limit = parse_int_param(params, "limit", 100)

    case Storage.list_summaries(tenant_id, document_id,
           from_sequence_number: from_sn,
           limit: limit
         ) do
      {:ok, summaries} ->
        json(conn, %{summaries: summaries})
    end
  end

  def refs(conn, %{"tenant_id" => tenant_id}) do
    case Storage.list_refs(tenant_id) do
      {:ok, refs} ->
        json(conn, %{refs: refs})
    end
  end

  def blob(conn, %{"tenant_id" => tenant_id, "sha" => sha}) do
    case Storage.get_blob(tenant_id, sha) do
      {:ok, blob} ->
        json(conn, %{blob: blob})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "not_found", message: "Blob not found"}})
    end
  end

  def tree(conn, %{"tenant_id" => tenant_id, "sha" => sha} = params) do
    recursive = params["recursive"] == "1" || params["recursive"] == "true"

    case Storage.get_tree(tenant_id, sha, recursive: recursive) do
      {:ok, tree} ->
        json(conn, %{tree: tree})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "not_found", message: "Tree not found"}})
    end
  end

  def commit(conn, %{"tenant_id" => tenant_id, "sha" => sha}) do
    case Storage.get_commit(tenant_id, sha) do
      {:ok, commit} ->
        json(conn, %{commit: commit})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "not_found", message: "Commit not found"}})
    end
  end

  defp parse_int_param(params, key, default) do
    case params[key] do
      nil -> default
      val -> String.to_integer(val)
    end
  rescue
    _ -> default
  end

  defp parse_optional_int_param(params, key) do
    case params[key] do
      nil -> nil
      val -> String.to_integer(val)
    end
  rescue
    _ -> nil
  end
end
