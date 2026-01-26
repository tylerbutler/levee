defmodule FluidServer.Storage.Behaviour do
  @moduledoc """
  Behaviour definition for the Fluid Framework storage backend.

  Defines the contract for storing and retrieving:
  - Documents and their metadata
  - Deltas (sequenced operations)
  - Git-like objects (blobs, trees, commits, refs)
  """

  @type tenant_id :: String.t()
  @type document_id :: String.t()
  @type sha :: String.t()
  @type ref_path :: String.t()

  @type document :: %{
          id: document_id(),
          tenant_id: tenant_id(),
          sequence_number: non_neg_integer(),
          created_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @type delta :: %{
          sequence_number: non_neg_integer(),
          client_id: String.t() | nil,
          client_sequence_number: non_neg_integer(),
          reference_sequence_number: non_neg_integer(),
          minimum_sequence_number: non_neg_integer(),
          type: String.t(),
          contents: term(),
          metadata: term(),
          timestamp: non_neg_integer()
        }

  @type blob :: %{
          sha: sha(),
          content: binary(),
          size: non_neg_integer()
        }

  @type tree_entry :: %{
          path: String.t(),
          mode: String.t(),
          sha: sha(),
          type: String.t()
        }

  @type tree :: %{
          sha: sha(),
          tree: [tree_entry()]
        }

  @type commit :: %{
          sha: sha(),
          tree: sha(),
          parents: [sha()],
          message: String.t(),
          author: %{name: String.t(), email: String.t(), date: String.t()},
          committer: %{name: String.t(), email: String.t(), date: String.t()}
        }

  @type ref :: %{
          ref: ref_path(),
          sha: sha()
        }

  # Document operations
  @callback create_document(tenant_id(), document_id(), map()) ::
              {:ok, document()} | {:error, term()}

  @callback get_document(tenant_id(), document_id()) ::
              {:ok, document()} | {:error, :not_found}

  @callback update_document_sequence(tenant_id(), document_id(), non_neg_integer()) ::
              {:ok, document()} | {:error, term()}

  # Delta operations
  @callback store_delta(tenant_id(), document_id(), delta()) ::
              {:ok, delta()} | {:error, term()}

  @callback get_deltas(tenant_id(), document_id(), opts :: keyword()) ::
              {:ok, [delta()]}

  # Blob operations
  @callback create_blob(tenant_id(), binary()) ::
              {:ok, blob()} | {:error, term()}

  @callback get_blob(tenant_id(), sha()) ::
              {:ok, blob()} | {:error, :not_found}

  # Tree operations
  @callback create_tree(tenant_id(), [tree_entry()]) ::
              {:ok, tree()} | {:error, term()}

  @callback get_tree(tenant_id(), sha(), opts :: keyword()) ::
              {:ok, tree()} | {:error, :not_found}

  # Commit operations
  @callback create_commit(tenant_id(), map()) ::
              {:ok, commit()} | {:error, term()}

  @callback get_commit(tenant_id(), sha()) ::
              {:ok, commit()} | {:error, :not_found}

  # Reference operations
  @callback create_ref(tenant_id(), ref_path(), sha()) ::
              {:ok, ref()} | {:error, term()}

  @callback get_ref(tenant_id(), ref_path()) ::
              {:ok, ref()} | {:error, :not_found}

  @callback list_refs(tenant_id()) ::
              {:ok, [ref()]}

  @callback update_ref(tenant_id(), ref_path(), sha()) ::
              {:ok, ref()} | {:error, term()}

  # Summary operations
  @type summary :: %{
          handle: String.t(),
          tenant_id: tenant_id(),
          document_id: document_id(),
          sequence_number: non_neg_integer(),
          tree_sha: sha(),
          commit_sha: sha() | nil,
          parent_handle: String.t() | nil,
          message: String.t() | nil,
          created_at: DateTime.t()
        }

  @callback store_summary(tenant_id(), document_id(), summary()) ::
              {:ok, summary()} | {:error, term()}

  @callback get_summary(tenant_id(), document_id(), handle :: String.t()) ::
              {:ok, summary()} | {:error, :not_found}

  @callback get_latest_summary(tenant_id(), document_id()) ::
              {:ok, summary()} | {:error, :not_found}

  @callback list_summaries(tenant_id(), document_id(), opts :: keyword()) ::
              {:ok, [summary()]}
end
