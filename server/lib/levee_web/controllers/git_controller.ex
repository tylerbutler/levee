defmodule LeveeWeb.GitController do
  @moduledoc """
  Controller for Fluid Framework Git-like storage operations.

  Implements the Git Storage Service HTTP API:
  - POST/GET /repos/:tenant_id/git/blobs - Blob storage
  - POST/GET /repos/:tenant_id/git/trees - Tree storage
  - POST/GET /repos/:tenant_id/git/commits - Commit storage
  - GET/POST/PATCH /repos/:tenant_id/git/refs - Reference management

  Storage calls and Plug/Conn handling stay here; the response *shape*
  (object/ref URLs, formatted response bodies) is delegated to Floodgate's
  `floodgate/rest` module via `Levee.Floodgate`, so the wire format for this
  Storage/Historian-style surface lives in one Floodgate-owned place. See
  `Levee.Floodgate` module docs for the broader migration context.
  """

  use LeveeWeb, :controller

  alias Levee.Storage
  alias Levee.Floodgate

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
      {:ok, blob} = Storage.create_blob(tenant_id, content)

      conn
      |> put_status(:created)
      |> json(%{
        sha: blob.sha,
        url: blob_url(conn, tenant_id, blob.sha)
      })
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
        |> json(
          Floodgate.format_blob_response(
            base_url(conn),
            tenant_id,
            blob.sha,
            blob.size,
            Base.encode64(blob.content)
          )
        )

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

    {:ok, tree} = Storage.create_tree(tenant_id, entries)

    conn
    |> put_status(:created)
    |> json(format_tree_response(conn, tenant_id, tree))
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
    {:ok, commit} = Storage.create_commit(tenant_id, params)

    conn
    |> put_status(:created)
    |> json(format_commit_response(conn, tenant_id, commit))
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

  @doc """
  List commit history, newest first, following first parents.

  GET /repos/:tenant_id/commits?sha=<ref-or-sha>&count=<n>

  This is Historian's commit-history endpoint, which the official Routerlicious
  driver calls from `getVersions`. It is not under `/git` because the driver's
  `storageUrl` is `/repos/:tenant_id`.

  `sha` is resolved as `refs/heads/<sha>` first (Fluid passes the document id),
  falling back to treating it as a literal commit SHA. An unresolvable or
  missing commit yields `[]`, matching Floodgate — a brand-new document has no
  history, and that is not an error.
  """
  def list_commits(conn, %{"tenant_id" => tenant_id, "sha" => requested} = params) do
    case parse_count(params) do
      {:ok, count} ->
        start_sha =
          case Storage.get_ref(tenant_id, "refs/heads/" <> requested) do
            {:ok, ref} -> ref.sha
            {:error, :not_found} -> requested
          end

        conn
        |> put_status(:ok)
        |> json(commit_history(conn, tenant_id, start_sha, count))

      :error ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "count must be a positive integer"})
    end
  end

  def list_commits(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Missing required query parameter: sha"})
  end

  # Reference operations

  @doc """
  List all references.

  GET /repos/:tenant_id/git/refs
  """
  def list_refs(conn, %{"tenant_id" => tenant_id}) do
    {:ok, refs} = Storage.list_refs(tenant_id)
    formatted_refs = Enum.map(refs, &format_ref_response(conn, tenant_id, &1))

    conn
    |> put_status(:ok)
    |> json(formatted_refs)
  end

  @doc """
  Get a reference by path.

  GET /repos/:tenant_id/git/refs/*ref
  Example: GET /repos/tenant1/git/refs/heads/main
  """
  def show_ref(conn, %{"tenant_id" => tenant_id, "ref" => ref_parts}) do
    ref_path = Floodgate.build_ref_path(ref_parts)

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
    ref_path = Floodgate.build_ref_path(ref_parts)

    case Storage.update_ref(tenant_id, ref_path, sha) do
      {:ok, ref} ->
        conn
        |> put_status(:ok)
        |> json(format_ref_response(conn, tenant_id, ref))

      {:error, :not_found} ->
        # Upsert: create the ref if it doesn't exist yet.
        # The Fluid Framework client calls PATCH (updateRef) even for the initial
        # summary upload, expecting create-if-not-exists semantics.
        case Storage.create_ref(tenant_id, ref_path, sha) do
          {:ok, ref} ->
            conn
            |> put_status(:ok)
            |> json(format_ref_response(conn, tenant_id, ref))

          {:error, reason} ->
            conn
            |> put_status(:bad_request)
            |> json(%{error: inspect(reason)})
        end

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
    Floodgate.blob_url(base_url(conn), tenant_id, sha)
  end

  defp base_url(conn) do
    Floodgate.base_url(conn.scheme, conn.host, conn.port)
  end

  defp format_tree_response(conn, tenant_id, tree) do
    entries =
      Enum.map(tree.tree, fn entry ->
        {entry.path, entry.mode, entry.sha, entry.type}
      end)

    Floodgate.format_tree_response(base_url(conn), tenant_id, tree.sha, entries)
  end

  defp format_commit_response(conn, tenant_id, commit) do
    Floodgate.format_commit_response(
      base_url(conn),
      tenant_id,
      commit.sha,
      commit.tree,
      commit.parents,
      commit.message,
      commit.author,
      commit.committer
    )
  end

  defp format_ref_response(conn, tenant_id, ref) do
    Floodgate.format_ref_response(base_url(conn), tenant_id, ref.ref, ref.sha)
  end

  defp parse_count(%{"count" => count}) when is_binary(count) do
    case Integer.parse(count) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_count(%{"count" => _}), do: :error
  defp parse_count(_), do: {:ok, 1}

  defp commit_history(_conn, _tenant_id, _sha, 0), do: []

  defp commit_history(conn, tenant_id, sha, count) do
    case Storage.get_commit(tenant_id, sha) do
      {:error, :not_found} ->
        []

      {:ok, commit} ->
        rest =
          case commit.parents do
            [parent | _] -> commit_history(conn, tenant_id, parent, count - 1)
            [] -> []
          end

        [commit_details(conn, tenant_id, commit) | rest]
    end
  end

  # ICommitDetails is a rearrangement of the ICommit fields Floodgate already
  # formats, so the URL shapes stay Floodgate-owned and only the nesting is
  # built here.
  defp commit_details(conn, tenant_id, commit) do
    formatted = format_commit_response(conn, tenant_id, commit)

    %{
      "sha" => formatted["sha"],
      "url" => formatted["url"],
      "commit" => %{
        "url" => formatted["url"],
        "author" => formatted["author"],
        "committer" => formatted["committer"],
        "message" => formatted["message"],
        "tree" => formatted["tree"]
      },
      "parents" => formatted["parents"]
    }
  end
end
