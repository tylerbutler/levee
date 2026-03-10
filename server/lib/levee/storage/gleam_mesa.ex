defmodule Levee.Storage.GleamMesa do
  @moduledoc """
  Mesa (Mnesia) storage backend scaffold implemented in Gleam via the levee_storage package.

  This module bridges the Elixir `Levee.Storage.Behaviour` interface to
  the Gleam `levee_storage` Mesa implementation.
  """

  use GenServer

  @behaviour Levee.Storage.Behaviour

  @gleam_mesa :levee_storage@mesa
  @interop :levee_storage@interop

  @compile {:no_warn_undefined,
            [
              :levee_storage,
              :levee_storage@mesa,
              :levee_storage@interop,
              :levee_storage@types
            ]}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    tables = @gleam_mesa.init()
    :persistent_term.put(:levee_storage_mesa_tables, tables)
    {:ok, %{tables: tables}}
  end

  defp tables do
    :persistent_term.get(:levee_storage_mesa_tables)
  end

  defp normalize_error({:storage_error, :not_implemented}), do: :not_implemented
  defp normalize_error({:storage_error, "not_implemented"}), do: :not_implemented
  defp normalize_error({:storage_error, reason}), do: reason
  defp normalize_error(reason), do: reason

  @impl Levee.Storage.Behaviour
  def create_document(tenant_id, document_id, params) do
    sn = params[:sequence_number] || 0

    case @gleam_mesa.create_document(tables(), tenant_id, document_id, sn) do
      {:ok, doc} -> {:ok, @interop.document_to_map(doc)}
      {:error, :already_exists} -> {:error, :already_exists}
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  @impl Levee.Storage.Behaviour
  def get_document(tenant_id, document_id) do
    case @gleam_mesa.get_document(tables(), tenant_id, document_id) do
      {:ok, doc} -> {:ok, @interop.document_to_map(doc)}
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  @impl Levee.Storage.Behaviour
  def list_documents(tenant_id) do
    case @gleam_mesa.list_documents(tables(), tenant_id) do
      {:ok, docs} -> {:ok, Enum.map(docs, &@interop.document_to_map/1)}
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  @impl Levee.Storage.Behaviour
  def update_document_sequence(tenant_id, document_id, sequence_number) do
    case @gleam_mesa.update_document_sequence(tables(), tenant_id, document_id, sequence_number) do
      {:ok, doc} -> {:ok, @interop.document_to_map(doc)}
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  @impl Levee.Storage.Behaviour
  def store_delta(tenant_id, document_id, delta) do
    gleam_delta = @interop.map_to_delta(delta)

    case @gleam_mesa.store_delta(tables(), tenant_id, document_id, gleam_delta) do
      {:ok, stored} -> {:ok, @interop.delta_to_map(stored)}
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  @impl Levee.Storage.Behaviour
  def get_deltas(tenant_id, document_id, opts \\ []) do
    from_sn = Keyword.get(opts, :from, -1)
    to_sn = Keyword.get(opts, :to, nil)
    limit = Keyword.get(opts, :limit, 2000)

    gleam_to_sn = if to_sn, do: {:some, to_sn}, else: :none

    case @gleam_mesa.get_deltas(tables(), tenant_id, document_id, from_sn, gleam_to_sn, limit) do
      {:ok, deltas} -> {:ok, Enum.map(deltas, &@interop.delta_to_map/1)}
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  @impl Levee.Storage.Behaviour
  def create_blob(tenant_id, content) when is_binary(content) do
    case @gleam_mesa.create_blob(tables(), tenant_id, content) do
      {:ok, blob} -> {:ok, @interop.blob_to_map(blob)}
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  @impl Levee.Storage.Behaviour
  def get_blob(tenant_id, sha) do
    case @gleam_mesa.get_blob(tables(), tenant_id, sha) do
      {:ok, blob} -> {:ok, @interop.blob_to_map(blob)}
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  @impl Levee.Storage.Behaviour
  def create_tree(tenant_id, entries) do
    gleam_entries = Enum.map(entries, &@interop.map_to_tree_entry/1)

    case @gleam_mesa.create_tree(tables(), tenant_id, gleam_entries) do
      {:ok, tree} -> {:ok, @interop.tree_to_map(tree)}
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  @impl Levee.Storage.Behaviour
  def get_tree(tenant_id, sha, opts \\ []) do
    recursive = Keyword.get(opts, :recursive, false)

    case @gleam_mesa.get_tree(tables(), tenant_id, sha, recursive) do
      {:ok, tree} -> {:ok, @interop.tree_to_map(tree)}
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  @impl Levee.Storage.Behaviour
  def create_commit(tenant_id, params) do
    tree_sha = params["tree"]
    parents = params["parents"] || []
    message = if params["message"], do: {:some, params["message"]}, else: :none
    author = params["author"]
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    committer =
      params["committer"] ||
        %{
          "name" => "Levee",
          "email" => "server@fluid.local",
          "date" => now
        }

    case @gleam_mesa.create_commit(
           tables(),
           tenant_id,
           tree_sha,
           parents,
           message,
           author,
           committer
         ) do
      {:ok, commit} -> {:ok, @interop.commit_to_map(commit)}
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  @impl Levee.Storage.Behaviour
  def get_commit(tenant_id, sha) do
    case @gleam_mesa.get_commit(tables(), tenant_id, sha) do
      {:ok, commit} -> {:ok, @interop.commit_to_map(commit)}
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  @impl Levee.Storage.Behaviour
  def create_ref(tenant_id, ref_path, sha) do
    case @gleam_mesa.create_ref(tables(), tenant_id, ref_path, sha) do
      {:ok, r} -> {:ok, @interop.ref_to_map(r)}
      {:error, :already_exists} -> {:error, :already_exists}
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  @impl Levee.Storage.Behaviour
  def get_ref(tenant_id, ref_path) do
    case @gleam_mesa.get_ref(tables(), tenant_id, ref_path) do
      {:ok, r} -> {:ok, @interop.ref_to_map(r)}
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  @impl Levee.Storage.Behaviour
  def list_refs(tenant_id) do
    case @gleam_mesa.list_refs(tables(), tenant_id) do
      {:ok, refs} -> {:ok, Enum.map(refs, &@interop.ref_to_map/1)}
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  @impl Levee.Storage.Behaviour
  def update_ref(tenant_id, ref_path, sha) do
    case @gleam_mesa.update_ref(tables(), tenant_id, ref_path, sha) do
      {:ok, r} -> {:ok, @interop.ref_to_map(r)}
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  @impl Levee.Storage.Behaviour
  def store_summary(tenant_id, document_id, summary) do
    gleam_summary = @interop.map_to_summary(summary)

    case @gleam_mesa.store_summary(tables(), tenant_id, document_id, gleam_summary) do
      {:ok, stored} -> {:ok, @interop.summary_to_map(stored)}
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  @impl Levee.Storage.Behaviour
  def get_summary(tenant_id, document_id, handle) do
    case @gleam_mesa.get_summary(tables(), tenant_id, document_id, handle) do
      {:ok, s} -> {:ok, @interop.summary_to_map(s)}
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  @impl Levee.Storage.Behaviour
  def get_latest_summary(tenant_id, document_id) do
    case @gleam_mesa.get_latest_summary(tables(), tenant_id, document_id) do
      {:ok, s} -> {:ok, @interop.summary_to_map(s)}
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  @impl Levee.Storage.Behaviour
  def list_summaries(tenant_id, document_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    from_sn = Keyword.get(opts, :from_sequence_number, 0)

    case @gleam_mesa.list_summaries(tables(), tenant_id, document_id, from_sn, limit) do
      {:ok, summaries} -> {:ok, Enum.map(summaries, &@interop.summary_to_map/1)}
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end
end
