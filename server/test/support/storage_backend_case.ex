defmodule Levee.StorageBackendCase do
  @moduledoc """
  Shared contract test suite for any module implementing `Levee.Storage.Behaviour`.

  ## Usage

      defmodule Levee.Storage.MyBackendTest do
        @backend Levee.Storage.MyBackend
        use Levee.StorageBackendCase
      end
  """

  defmacro __using__(_opts) do
    quote do
      use ExUnit.Case, async: false

      @moduletag :storage_backend

      defp unique_id(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

      defp make_delta(attrs) do
        Map.merge(
          %{
            sequence_number: 1,
            client_id: "test-client",
            client_sequence_number: 1,
            reference_sequence_number: 0,
            minimum_sequence_number: 0,
            type: "Join",
            contents: nil,
            metadata: nil,
            timestamp: System.system_time(:millisecond)
          },
          attrs
        )
      end

      defp make_summary(attrs) do
        Map.merge(
          %{
            handle: unique_id("handle"),
            sequence_number: 0,
            tree_sha: "abc123",
            commit_sha: nil,
            parent_handle: nil,
            message: nil
          },
          attrs
        )
      end

      setup do
        {:ok, _} = Application.ensure_all_started(:levee)
        tenant_id = unique_id("tenant")
        {:ok, tenant_id: tenant_id}
      end

      # -----------------------------------------------------------------------
      # Document operations
      # -----------------------------------------------------------------------

      describe "create_document/3" do
        test "creates a document and returns its metadata", %{tenant_id: tid} do
          doc_id = unique_id("doc")
          assert {:ok, doc} = @backend.create_document(tid, doc_id, %{sequence_number: 0})

          assert doc.id == doc_id
          assert doc.tenant_id == tid
          assert doc.sequence_number == 0
          assert %DateTime{} = doc.created_at
          assert %DateTime{} = doc.updated_at
        end

        test "returns error when document already exists", %{tenant_id: tid} do
          doc_id = unique_id("doc")
          assert {:ok, _} = @backend.create_document(tid, doc_id, %{sequence_number: 0})
          assert {:error, :already_exists} = @backend.create_document(tid, doc_id, %{})
        end

        test "same document ID in different tenants does not conflict", %{tenant_id: tid} do
          tid2 = unique_id("tenant")
          doc_id = unique_id("doc")

          assert {:ok, d1} = @backend.create_document(tid, doc_id, %{sequence_number: 0})
          assert {:ok, d2} = @backend.create_document(tid2, doc_id, %{sequence_number: 5})

          assert d1.tenant_id == tid
          assert d2.tenant_id == tid2
        end
      end

      describe "get_document/2" do
        test "retrieves a previously created document", %{tenant_id: tid} do
          doc_id = unique_id("doc")
          {:ok, created} = @backend.create_document(tid, doc_id, %{sequence_number: 0})
          assert {:ok, fetched} = @backend.get_document(tid, doc_id)

          assert fetched.id == created.id
          assert fetched.tenant_id == created.tenant_id
        end

        test "returns not_found for nonexistent document", %{tenant_id: tid} do
          assert {:error, :not_found} = @backend.get_document(tid, "nonexistent")
        end

        test "tenant isolation: cannot see another tenant's document", %{tenant_id: tid} do
          tid2 = unique_id("tenant")
          doc_id = unique_id("doc")
          {:ok, _} = @backend.create_document(tid, doc_id, %{})

          assert {:error, :not_found} = @backend.get_document(tid2, doc_id)
        end
      end

      describe "update_document_sequence/3" do
        test "updates the sequence number", %{tenant_id: tid} do
          doc_id = unique_id("doc")
          {:ok, _} = @backend.create_document(tid, doc_id, %{sequence_number: 0})

          assert {:ok, updated} = @backend.update_document_sequence(tid, doc_id, 42)
          assert updated.sequence_number == 42
        end

        test "returns not_found for nonexistent document", %{tenant_id: tid} do
          assert {:error, :not_found} = @backend.update_document_sequence(tid, "nope", 1)
        end
      end

      # -----------------------------------------------------------------------
      # Delta operations
      # -----------------------------------------------------------------------

      describe "store_delta/3" do
        test "stores and returns a delta", %{tenant_id: tid} do
          doc_id = unique_id("doc")
          {:ok, _} = @backend.create_document(tid, doc_id, %{})

          delta = make_delta(%{sequence_number: 1, client_id: "c1"})
          assert {:ok, stored} = @backend.store_delta(tid, doc_id, delta)
          assert stored.sequence_number == 1
          assert stored.client_id == "c1"
        end
      end

      describe "get_deltas/3" do
        test "returns stored deltas in order", %{tenant_id: tid} do
          doc_id = unique_id("doc")
          {:ok, _} = @backend.create_document(tid, doc_id, %{})

          for sn <- 1..3 do
            @backend.store_delta(tid, doc_id, make_delta(%{sequence_number: sn}))
          end

          assert {:ok, deltas} = @backend.get_deltas(tid, doc_id, from: 0)
          assert length(deltas) == 3
          assert Enum.map(deltas, & &1.sequence_number) == [1, 2, 3]
        end

        test "filters deltas by from/to range", %{tenant_id: tid} do
          doc_id = unique_id("doc")
          {:ok, _} = @backend.create_document(tid, doc_id, %{})

          for sn <- 1..5 do
            @backend.store_delta(tid, doc_id, make_delta(%{sequence_number: sn}))
          end

          assert {:ok, deltas} = @backend.get_deltas(tid, doc_id, from: 2, to: 4)
          sns = Enum.map(deltas, & &1.sequence_number)
          assert Enum.all?(sns, &(&1 >= 2 and &1 <= 4))
        end

        test "respects limit option", %{tenant_id: tid} do
          doc_id = unique_id("doc")
          {:ok, _} = @backend.create_document(tid, doc_id, %{})

          for sn <- 1..10 do
            @backend.store_delta(tid, doc_id, make_delta(%{sequence_number: sn}))
          end

          assert {:ok, deltas} = @backend.get_deltas(tid, doc_id, from: 0, limit: 3)
          assert length(deltas) == 3
        end

        test "returns empty list for nonexistent document", %{tenant_id: tid} do
          assert {:ok, []} = @backend.get_deltas(tid, "no-such-doc", from: 0)
        end

        test "tenant isolation: deltas not visible across tenants", %{tenant_id: tid} do
          tid2 = unique_id("tenant")
          doc_id = unique_id("doc")
          {:ok, _} = @backend.create_document(tid, doc_id, %{})
          @backend.store_delta(tid, doc_id, make_delta(%{sequence_number: 1}))

          assert {:ok, []} = @backend.get_deltas(tid2, doc_id, from: 0)
        end
      end

      # -----------------------------------------------------------------------
      # Blob operations
      # -----------------------------------------------------------------------

      describe "create_blob/2" do
        test "creates a blob with SHA-256 hash", %{tenant_id: tid} do
          content = "hello world"
          assert {:ok, blob} = @backend.create_blob(tid, content)

          expected_sha = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
          assert blob.sha == expected_sha
          assert blob.content == content
          assert blob.size == byte_size(content)
        end

        test "is idempotent: same content returns same SHA", %{tenant_id: tid} do
          content = "idempotent-content-#{unique_id("blob")}"
          {:ok, b1} = @backend.create_blob(tid, content)
          {:ok, b2} = @backend.create_blob(tid, content)
          assert b1.sha == b2.sha
        end
      end

      describe "get_blob/2" do
        test "retrieves a stored blob by SHA", %{tenant_id: tid} do
          content = "blob-content-#{unique_id("blob")}"
          {:ok, created} = @backend.create_blob(tid, content)

          assert {:ok, fetched} = @backend.get_blob(tid, created.sha)
          assert fetched.content == content
        end

        test "returns not_found for unknown SHA", %{tenant_id: tid} do
          assert {:error, :not_found} = @backend.get_blob(tid, "deadbeef")
        end

        test "tenant isolation: blob not visible to other tenant", %{tenant_id: tid} do
          tid2 = unique_id("tenant")
          {:ok, blob} = @backend.create_blob(tid, "secret")

          assert {:error, :not_found} = @backend.get_blob(tid2, blob.sha)
        end
      end

      # -----------------------------------------------------------------------
      # Tree operations
      # -----------------------------------------------------------------------

      describe "create_tree/2" do
        test "creates a tree with entries", %{tenant_id: tid} do
          {:ok, blob} = @backend.create_blob(tid, "file content")

          entries = [
            %{path: "README.md", mode: "100644", sha: blob.sha, type: "blob"}
          ]

          assert {:ok, tree} = @backend.create_tree(tid, entries)
          assert is_binary(tree.sha)
          assert length(tree.tree) == 1

          [entry] = tree.tree
          assert entry.path == "README.md"
          assert entry.sha == blob.sha
        end
      end

      describe "get_tree/3" do
        test "retrieves a stored tree", %{tenant_id: tid} do
          {:ok, blob} = @backend.create_blob(tid, "content")

          entries = [%{path: "file.txt", mode: "100644", sha: blob.sha, type: "blob"}]
          {:ok, created} = @backend.create_tree(tid, entries)

          assert {:ok, fetched} = @backend.get_tree(tid, created.sha)
          assert fetched.sha == created.sha
          assert length(fetched.tree) == 1
        end

        test "returns not_found for unknown SHA", %{tenant_id: tid} do
          assert {:error, :not_found} = @backend.get_tree(tid, "badsha")
        end

        test "recursive option expands subtrees", %{tenant_id: tid} do
          {:ok, blob} = @backend.create_blob(tid, "nested content")

          {:ok, subtree} =
            @backend.create_tree(tid, [
              %{path: "nested.txt", mode: "100644", sha: blob.sha, type: "blob"}
            ])

          {:ok, root_tree} =
            @backend.create_tree(tid, [
              %{path: "subdir", mode: "040000", sha: subtree.sha, type: "tree"}
            ])

          assert {:ok, flat} = @backend.get_tree(tid, root_tree.sha, recursive: false)
          assert length(flat.tree) == 1

          assert {:ok, expanded} = @backend.get_tree(tid, root_tree.sha, recursive: true)
          paths = Enum.map(expanded.tree, & &1.path)
          assert "subdir/nested.txt" in paths
        end

        test "tenant isolation: tree not visible to other tenant", %{tenant_id: tid} do
          tid2 = unique_id("tenant")
          {:ok, blob} = @backend.create_blob(tid, "x")

          {:ok, tree} =
            @backend.create_tree(tid, [
              %{path: "a.txt", mode: "100644", sha: blob.sha, type: "blob"}
            ])

          assert {:error, :not_found} = @backend.get_tree(tid2, tree.sha)
        end
      end

      # -----------------------------------------------------------------------
      # Commit operations
      # -----------------------------------------------------------------------

      describe "create_commit/2" do
        test "creates a commit with tree and author", %{tenant_id: tid} do
          {:ok, blob} = @backend.create_blob(tid, "commit test")

          {:ok, tree} =
            @backend.create_tree(tid, [
              %{path: "file.txt", mode: "100644", sha: blob.sha, type: "blob"}
            ])

          params = %{
            "tree" => tree.sha,
            "parents" => [],
            "message" => "initial commit",
            "author" => %{
              "name" => "Test User",
              "email" => "test@example.com",
              "date" => DateTime.utc_now() |> DateTime.to_iso8601()
            }
          }

          assert {:ok, commit} = @backend.create_commit(tid, params)
          assert is_binary(commit.sha)
          assert commit.tree == tree.sha
          assert commit.parents == []
          assert commit.message == "initial commit"
          assert commit.author["name"] == "Test User"
        end

        test "defaults committer when not provided", %{tenant_id: tid} do
          {:ok, blob} = @backend.create_blob(tid, "c")

          {:ok, tree} =
            @backend.create_tree(tid, [
              %{path: "f.txt", mode: "100644", sha: blob.sha, type: "blob"}
            ])

          params = %{
            "tree" => tree.sha,
            "parents" => [],
            "message" => nil,
            "author" => %{
              "name" => "A",
              "email" => "a@a.com",
              "date" => "2024-01-01T00:00:00Z"
            }
          }

          assert {:ok, commit} = @backend.create_commit(tid, params)
          assert commit.committer != nil
          assert is_binary(commit.committer["name"])
        end

        test "supports parent commits", %{tenant_id: tid} do
          {:ok, blob} = @backend.create_blob(tid, "parent test")

          {:ok, tree} =
            @backend.create_tree(tid, [
              %{path: "f.txt", mode: "100644", sha: blob.sha, type: "blob"}
            ])

          author = %{"name" => "A", "email" => "a@a.com", "date" => "2024-01-01T00:00:00Z"}

          {:ok, parent} =
            @backend.create_commit(tid, %{
              "tree" => tree.sha,
              "parents" => [],
              "message" => "first",
              "author" => author
            })

          {:ok, child} =
            @backend.create_commit(tid, %{
              "tree" => tree.sha,
              "parents" => [parent.sha],
              "message" => "second",
              "author" => author
            })

          assert child.parents == [parent.sha]
        end
      end

      describe "get_commit/2" do
        test "retrieves a stored commit", %{tenant_id: tid} do
          {:ok, blob} = @backend.create_blob(tid, "gc")

          {:ok, tree} =
            @backend.create_tree(tid, [
              %{path: "x.txt", mode: "100644", sha: blob.sha, type: "blob"}
            ])

          {:ok, commit} =
            @backend.create_commit(tid, %{
              "tree" => tree.sha,
              "parents" => [],
              "message" => "m",
              "author" => %{"name" => "N", "email" => "e@e.com", "date" => "2024-01-01T00:00:00Z"}
            })

          assert {:ok, fetched} = @backend.get_commit(tid, commit.sha)
          assert fetched.sha == commit.sha
          assert fetched.message == "m"
        end

        test "returns not_found for unknown SHA", %{tenant_id: tid} do
          assert {:error, :not_found} = @backend.get_commit(tid, "missing-sha")
        end

        test "tenant isolation: commit not visible to other tenant", %{tenant_id: tid} do
          tid2 = unique_id("tenant")
          {:ok, blob} = @backend.create_blob(tid, "iso")

          {:ok, tree} =
            @backend.create_tree(tid, [
              %{path: "i.txt", mode: "100644", sha: blob.sha, type: "blob"}
            ])

          {:ok, commit} =
            @backend.create_commit(tid, %{
              "tree" => tree.sha,
              "parents" => [],
              "message" => "iso",
              "author" => %{"name" => "N", "email" => "e@e.com", "date" => "2024-01-01T00:00:00Z"}
            })

          assert {:error, :not_found} = @backend.get_commit(tid2, commit.sha)
        end
      end

      # -----------------------------------------------------------------------
      # Reference operations
      # -----------------------------------------------------------------------

      describe "create_ref/3" do
        test "creates a ref", %{tenant_id: tid} do
          ref_path = "refs/heads/#{unique_id("branch")}"
          sha = "abc123"
          assert {:ok, ref} = @backend.create_ref(tid, ref_path, sha)
          assert ref.ref == ref_path
          assert ref.sha == sha
        end

        test "returns error when ref already exists", %{tenant_id: tid} do
          ref_path = "refs/heads/#{unique_id("branch")}"
          {:ok, _} = @backend.create_ref(tid, ref_path, "sha1")
          assert {:error, :already_exists} = @backend.create_ref(tid, ref_path, "sha2")
        end
      end

      describe "get_ref/2" do
        test "retrieves a stored ref", %{tenant_id: tid} do
          ref_path = "refs/heads/#{unique_id("branch")}"
          {:ok, _} = @backend.create_ref(tid, ref_path, "sha-val")

          assert {:ok, ref} = @backend.get_ref(tid, ref_path)
          assert ref.sha == "sha-val"
        end

        test "returns not_found for nonexistent ref", %{tenant_id: tid} do
          assert {:error, :not_found} = @backend.get_ref(tid, "refs/heads/nope")
        end

        test "tenant isolation: ref not visible to other tenant", %{tenant_id: tid} do
          tid2 = unique_id("tenant")
          ref_path = "refs/heads/#{unique_id("branch")}"
          {:ok, _} = @backend.create_ref(tid, ref_path, "s")

          assert {:error, :not_found} = @backend.get_ref(tid2, ref_path)
        end
      end

      describe "list_refs/1" do
        test "lists all refs for a tenant", %{tenant_id: tid} do
          {:ok, _} = @backend.create_ref(tid, "refs/heads/main", "sha1")
          {:ok, _} = @backend.create_ref(tid, "refs/heads/dev", "sha2")

          assert {:ok, refs} = @backend.list_refs(tid)
          ref_paths = Enum.map(refs, & &1.ref)
          assert "refs/heads/main" in ref_paths
          assert "refs/heads/dev" in ref_paths
        end

        test "returns empty list for tenant with no refs", %{tenant_id: tid} do
          assert {:ok, []} = @backend.list_refs(tid)
        end

        test "tenant isolation: only lists own tenant's refs", %{tenant_id: tid} do
          tid2 = unique_id("tenant")
          {:ok, _} = @backend.create_ref(tid, "refs/heads/a", "sha1")
          {:ok, _} = @backend.create_ref(tid2, "refs/heads/b", "sha2")

          {:ok, refs} = @backend.list_refs(tid)
          ref_paths = Enum.map(refs, & &1.ref)
          assert "refs/heads/a" in ref_paths
          refute "refs/heads/b" in ref_paths
        end
      end

      describe "update_ref/3" do
        test "updates an existing ref's SHA", %{tenant_id: tid} do
          ref_path = "refs/heads/#{unique_id("branch")}"
          {:ok, _} = @backend.create_ref(tid, ref_path, "old-sha")

          assert {:ok, ref} = @backend.update_ref(tid, ref_path, "new-sha")
          assert ref.sha == "new-sha"

          {:ok, fetched} = @backend.get_ref(tid, ref_path)
          assert fetched.sha == "new-sha"
        end

        test "returns not_found for nonexistent ref", %{tenant_id: tid} do
          assert {:error, :not_found} = @backend.update_ref(tid, "refs/heads/nope", "sha")
        end
      end

      # -----------------------------------------------------------------------
      # Summary operations
      # -----------------------------------------------------------------------

      describe "store_summary/3" do
        test "stores and returns a summary", %{tenant_id: tid} do
          doc_id = unique_id("doc")
          {:ok, _} = @backend.create_document(tid, doc_id, %{})

          summary =
            make_summary(%{
              handle: "handle-1",
              sequence_number: 0,
              tree_sha: "tree-sha-1"
            })

          assert {:ok, stored} = @backend.store_summary(tid, doc_id, summary)
          assert stored.handle == "handle-1"
          assert stored.tenant_id == tid
          assert stored.document_id == doc_id
          assert stored.tree_sha == "tree-sha-1"
          assert %DateTime{} = stored.created_at
        end
      end

      describe "get_summary/3" do
        test "retrieves a stored summary by handle", %{tenant_id: tid} do
          doc_id = unique_id("doc")
          {:ok, _} = @backend.create_document(tid, doc_id, %{})

          handle = unique_id("handle")
          summary = make_summary(%{handle: handle, sequence_number: 5, tree_sha: "ts"})
          {:ok, _} = @backend.store_summary(tid, doc_id, summary)

          assert {:ok, fetched} = @backend.get_summary(tid, doc_id, handle)
          assert fetched.handle == handle
          assert fetched.sequence_number == 5
        end

        test "returns not_found for unknown handle", %{tenant_id: tid} do
          doc_id = unique_id("doc")
          assert {:error, :not_found} = @backend.get_summary(tid, doc_id, "nonexistent")
        end

        test "tenant isolation: summary not visible to other tenant", %{tenant_id: tid} do
          tid2 = unique_id("tenant")
          doc_id = unique_id("doc")
          {:ok, _} = @backend.create_document(tid, doc_id, %{})

          handle = unique_id("handle")
          summary = make_summary(%{handle: handle, sequence_number: 0, tree_sha: "x"})
          {:ok, _} = @backend.store_summary(tid, doc_id, summary)

          assert {:error, :not_found} = @backend.get_summary(tid2, doc_id, handle)
        end
      end

      describe "get_latest_summary/2" do
        test "returns the most recently stored summary", %{tenant_id: tid} do
          doc_id = unique_id("doc")
          {:ok, _} = @backend.create_document(tid, doc_id, %{})

          s1 = make_summary(%{handle: "h1", sequence_number: 1, tree_sha: "t1"})
          s2 = make_summary(%{handle: "h2", sequence_number: 5, tree_sha: "t2"})
          {:ok, _} = @backend.store_summary(tid, doc_id, s1)
          {:ok, _} = @backend.store_summary(tid, doc_id, s2)

          assert {:ok, latest} = @backend.get_latest_summary(tid, doc_id)
          assert latest.handle == "h2"
          assert latest.sequence_number == 5
        end

        test "returns not_found when no summaries exist", %{tenant_id: tid} do
          assert {:error, :not_found} = @backend.get_latest_summary(tid, "no-doc")
        end
      end

      describe "list_summaries/3" do
        test "lists summaries with filtering and limit", %{tenant_id: tid} do
          doc_id = unique_id("doc")
          {:ok, _} = @backend.create_document(tid, doc_id, %{})

          for sn <- [0, 5, 10, 15] do
            s =
              make_summary(%{
                handle: "h-#{sn}",
                sequence_number: sn,
                tree_sha: "t-#{sn}"
              })

            {:ok, _} = @backend.store_summary(tid, doc_id, s)
          end

          assert {:ok, all} = @backend.list_summaries(tid, doc_id, [])
          assert length(all) == 4

          assert {:ok, limited} = @backend.list_summaries(tid, doc_id, limit: 2)
          assert length(limited) == 2

          assert {:ok, from_five} = @backend.list_summaries(tid, doc_id, from_sequence_number: 5)
          sns = Enum.map(from_five, & &1.sequence_number)
          assert Enum.all?(sns, &(&1 >= 5))
        end

        test "returns empty list when no summaries exist", %{tenant_id: tid} do
          assert {:ok, []} = @backend.list_summaries(tid, "no-such-doc", [])
        end

        test "tenant isolation: summaries not visible across tenants", %{tenant_id: tid} do
          tid2 = unique_id("tenant")
          doc_id = unique_id("doc")
          {:ok, _} = @backend.create_document(tid, doc_id, %{})

          s = make_summary(%{handle: "h", sequence_number: 0, tree_sha: "t"})
          {:ok, _} = @backend.store_summary(tid, doc_id, s)

          assert {:ok, []} = @backend.list_summaries(tid2, doc_id, [])
        end
      end
    end
  end
end
