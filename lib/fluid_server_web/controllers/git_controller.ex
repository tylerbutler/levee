defmodule FluidServerWeb.GitController do
  @moduledoc """
  Controller for Fluid Framework Git-like storage operations.

  Implements the Git Storage Service HTTP API:
  - POST/GET /repos/:tenant_id/git/blobs - Blob storage
  - POST/GET /repos/:tenant_id/git/trees - Tree storage
  - POST/GET /repos/:tenant_id/git/commits - Commit storage
  - GET/POST/PATCH /repos/:tenant_id/git/refs - Reference management
  """

  use FluidServerWeb, :controller

  alias FluidServer.Storage.ETS, as: Storage

  # Blob operations

  @doc """
  Create a new blob.

  POST /repos/:tenant_id/git/blobs

  Request body:
  - content: Base64-encoded content
  - encoding: "base64"
  """
  def create_blob(conn, %{"tenant_id" => tenant_id} = params) do
    with {:ok, content} <- decode_blob_content(params) do
      case Storage.create_blob(tenant_id, content) do
        {:ok, blob} ->
          conn
          |> put_status(:created)
          |> json(%{
            sha: blob.sha,
            url: blob_url(conn, tenant_id, blob.sha)
          })

        {:error, reason} ->
          conn
          |> put_status(:bad_request)
          |> json(%{error: inspect(reason)})
      end
    else
      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: reason})
    end
  end

  @doc """
  Get a blob by SHA.

  GET /repos/:tenant_id/git/blobs/:sha
  """
  def show_blob(conn, %{"tenant_id" => tenant_id, "sha" => sha}) do
    case Storage.get_blob(tenant_id, sha) do
      {:ok, blob} ->
        conn
        |> put_resp_header("cache-control", "public, max-age=31536000")
        |> put_status(:ok)
        |> json(%{
          sha: blob.sha,
          size: blob.size,
          content: Base.encode64(blob.content),
          encoding: "base64",
          url: blob_url(conn, tenant_id, blob.sha)
        })

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Blob not found"})
    end
  end

  # Tree operations

  @doc """
  Create a new tree.

  POST /repos/:tenant_id/git/trees

  Request body:
  - tree: Array of tree entries
    - path: File/directory name
    - mode: File mode (e.g., "100644" for file)
    - sha: SHA of blob or tree
    - type: "blob" | "tree"
  """
  def create_tree(conn, %{"tenant_id" => tenant_id, "tree" => tree_entries}) do
    # Normalize and validate entries
    entries =
      Enum.map(tree_entries, fn entry ->
        %{
          path: entry["path"],
          mode: entry["mode"] || "100644",
          sha: entry["sha"],
          type: entry["type"] || "blob"
        }
      end)

    case Storage.create_tree(tenant_id, entries) do
      {:ok, tree} ->
        conn
        |> put_status(:created)
        |> json(format_tree_response(conn, tenant_id, tree))

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: inspect(reason)})
    end
  end

  @doc """
  Get a tree by SHA.

  GET /repos/:tenant_id/git/trees/:sha
  GET /repos/:tenant_id/git/trees/:sha?recursive=1
  """
  def show_tree(conn, %{"tenant_id" => tenant_id, "sha" => sha} = params) do
    recursive = params["recursive"] == "1"

    case Storage.get_tree(tenant_id, sha, recursive: recursive) do
      {:ok, tree} ->
        conn
        |> put_status(:ok)
        |> json(format_tree_response(conn, tenant_id, tree))

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Tree not found"})
    end
  end

  # Commit operations

  @doc """
  Create a new commit.

  POST /repos/:tenant_id/git/commits

  Request body:
  - tree: Tree SHA
  - parents: Parent commit SHAs
  - message: Commit message
  - author: { name, email, date }
  """
  def create_commit(conn, %{"tenant_id" => tenant_id} = params) do
    case Storage.create_commit(tenant_id, params) do
      {:ok, commit} ->
        conn
        |> put_status(:created)
        |> json(format_commit_response(conn, tenant_id, commit))

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: inspect(reason)})
    end
  end

  @doc """
  Get a commit by SHA.

  GET /repos/:tenant_id/git/commits/:sha
  """
  def show_commit(conn, %{"tenant_id" => tenant_id, "sha" => sha}) do
    case Storage.get_commit(tenant_id, sha) do
      {:ok, commit} ->
        conn
        |> put_status(:ok)
        |> json(format_commit_response(conn, tenant_id, commit))

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Commit not found"})
    end
  end

  # Reference operations

  @doc """
  List all references.

  GET /repos/:tenant_id/git/refs
  """
  def list_refs(conn, %{"tenant_id" => tenant_id}) do
    case Storage.list_refs(tenant_id) do
      {:ok, refs} ->
        formatted_refs = Enum.map(refs, &format_ref_response(conn, tenant_id, &1))

        conn
        |> put_status(:ok)
        |> json(formatted_refs)
    end
  end

  @doc """
  Get a reference by path.

  GET /repos/:tenant_id/git/refs/*ref
  Example: GET /repos/tenant1/git/refs/heads/main
  """
  def show_ref(conn, %{"tenant_id" => tenant_id, "ref" => ref_parts}) do
    ref_path = build_ref_path(ref_parts)

    case Storage.get_ref(tenant_id, ref_path) do
      {:ok, ref} ->
        conn
        |> put_status(:ok)
        |> json(format_ref_response(conn, tenant_id, ref))

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Reference not found"})
    end
  end

  @doc """
  Create a new reference.

  POST /repos/:tenant_id/git/refs

  Request body:
  - ref: Reference path (e.g., "refs/heads/main")
  - sha: Commit SHA
  """
  def create_ref(conn, %{"tenant_id" => tenant_id, "ref" => ref_path, "sha" => sha}) do
    case Storage.create_ref(tenant_id, ref_path, sha) do
      {:ok, ref} ->
        conn
        |> put_status(:created)
        |> json(format_ref_response(conn, tenant_id, ref))

      {:error, :already_exists} ->
        conn
        |> put_status(:conflict)
        |> json(%{error: "Reference already exists"})

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: inspect(reason)})
    end
  end

  @doc """
  Update a reference.

  PATCH /repos/:tenant_id/git/refs/*ref

  Request body:
  - sha: New commit SHA
  """
  def update_ref(conn, %{"tenant_id" => tenant_id, "ref" => ref_parts, "sha" => sha}) do
    ref_path = build_ref_path(ref_parts)

    case Storage.update_ref(tenant_id, ref_path, sha) do
      {:ok, ref} ->
        conn
        |> put_status(:ok)
        |> json(format_ref_response(conn, tenant_id, ref))

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Reference not found"})

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: inspect(reason)})
    end
  end

  # Private helpers

  defp decode_blob_content(%{"content" => content, "encoding" => "base64"}) do
    case Base.decode64(content) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, "Invalid base64 content"}
    end
  end

  defp decode_blob_content(%{"content" => content}) when is_binary(content) do
    {:ok, content}
  end

  defp decode_blob_content(_), do: {:error, "Missing or invalid content"}

  defp blob_url(conn, tenant_id, sha) do
    "#{base_url(conn)}/repos/#{tenant_id}/git/blobs/#{sha}"
  end

  defp tree_url(conn, tenant_id, sha) do
    "#{base_url(conn)}/repos/#{tenant_id}/git/trees/#{sha}"
  end

  defp commit_url(conn, tenant_id, sha) do
    "#{base_url(conn)}/repos/#{tenant_id}/git/commits/#{sha}"
  end

  defp ref_url(conn, tenant_id, ref_path) do
    # Remove "refs/" prefix for URL
    path = String.replace_prefix(ref_path, "refs/", "")
    "#{base_url(conn)}/repos/#{tenant_id}/git/refs/#{path}"
  end

  defp base_url(conn) do
    port_suffix =
      case {conn.scheme, conn.port} do
        {:http, 80} -> ""
        {:https, 443} -> ""
        {_, port} -> ":#{port}"
      end

    "#{conn.scheme}://#{conn.host}#{port_suffix}"
  end

  defp format_tree_response(conn, tenant_id, tree) do
    formatted_entries =
      Enum.map(tree.tree, fn entry ->
        entry_url =
          case entry.type do
            "blob" -> blob_url(conn, tenant_id, entry.sha)
            "tree" -> tree_url(conn, tenant_id, entry.sha)
            _ -> nil
          end

        %{
          path: entry.path,
          mode: entry.mode,
          sha: entry.sha,
          type: entry.type,
          url: entry_url
        }
      end)

    %{
      sha: tree.sha,
      url: tree_url(conn, tenant_id, tree.sha),
      tree: formatted_entries
    }
  end

  defp format_commit_response(conn, tenant_id, commit) do
    %{
      sha: commit.sha,
      tree: %{
        sha: commit.tree,
        url: tree_url(conn, tenant_id, commit.tree)
      },
      parents:
        Enum.map(commit.parents, fn parent_sha ->
          %{
            sha: parent_sha,
            url: commit_url(conn, tenant_id, parent_sha)
          }
        end),
      message: commit.message,
      author: commit.author,
      committer: commit.committer,
      url: commit_url(conn, tenant_id, commit.sha)
    }
  end

  defp format_ref_response(conn, tenant_id, ref) do
    %{
      ref: ref.ref,
      object: %{
        sha: ref.sha,
        type: "commit",
        url: commit_url(conn, tenant_id, ref.sha)
      },
      url: ref_url(conn, tenant_id, ref.ref)
    }
  end

  defp build_ref_path(ref_parts) when is_list(ref_parts) do
    "refs/" <> Enum.join(ref_parts, "/")
  end

  defp build_ref_path(ref_path) when is_binary(ref_path) do
    if String.starts_with?(ref_path, "refs/") do
      ref_path
    else
      "refs/" <> ref_path
    end
  end
end
