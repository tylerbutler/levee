defmodule LeveeWeb.GitControllerTest do
  use LeveeWeb.ConnCase

  alias Levee.Auth.JWT
  alias Levee.Auth.TenantSecrets

  @tenant_id "git-controller-test-tenant"
  @user_id "test-user"

  setup do
    {:ok, _} = Application.ensure_all_started(:levee)

    TenantSecrets.register_tenant(@tenant_id, "test-secret-key-for-git-controller-tests")
    on_exit(fn -> TenantSecrets.unregister_tenant(@tenant_id) end)

    :ok
  end

  defp token(scopes) do
    {:ok, token} =
      JWT.generate_test_token(@tenant_id, "doc-for-git-tests", @user_id, scopes: scopes)

    token
  end

  defp read_token, do: token(["doc:read"])
  defp write_token, do: token(["doc:read", "doc:write", "summary:read", "summary:write"])

  defp authed(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  describe "POST /repos/:tenant_id/git/blobs" do
    test "creates a blob and returns sha + url (no size/content/encoding)", %{conn: conn} do
      conn =
        conn
        |> authed(write_token())
        |> put_req_header("content-type", "application/json")
        |> post("/repos/#{@tenant_id}/git/blobs", %{
          "content" => Base.encode64("hello world"),
          "encoding" => "base64"
        })

      body = json_response(conn, 201)
      assert Map.keys(body) |> Enum.sort() == ["sha", "url"]
      assert String.ends_with?(body["url"], "/repos/#{@tenant_id}/git/blobs/#{body["sha"]}")
    end

    test "rejects invalid base64 content", %{conn: conn} do
      conn =
        conn
        |> authed(write_token())
        |> put_req_header("content-type", "application/json")
        |> post("/repos/#{@tenant_id}/git/blobs", %{
          "content" => "not-valid-base64!!",
          "encoding" => "base64"
        })

      assert %{"error" => _} = json_response(conn, 400)
    end
  end

  describe "GET /repos/:tenant_id/git/blobs/:sha" do
    test "returns the full blob shape (sha, size, content, encoding, url)", %{conn: conn} do
      create_conn =
        conn
        |> authed(write_token())
        |> put_req_header("content-type", "application/json")
        |> post("/repos/#{@tenant_id}/git/blobs", %{
          "content" => Base.encode64("hello world"),
          "encoding" => "base64"
        })

      %{"sha" => sha} = json_response(create_conn, 201)

      show_conn =
        conn
        |> authed(read_token())
        |> get("/repos/#{@tenant_id}/git/blobs/#{sha}")

      body = json_response(show_conn, 200)

      assert body["sha"] == sha
      assert body["size"] == 11
      assert body["encoding"] == "base64"
      assert Base.decode64!(body["content"]) == "hello world"
      assert String.ends_with?(body["url"], "/repos/#{@tenant_id}/git/blobs/#{sha}")
    end

    test "404s for an unknown blob sha", %{conn: conn} do
      conn =
        conn
        |> authed(read_token())
        |> get("/repos/#{@tenant_id}/git/blobs/does-not-exist")

      assert %{"error" => "Blob not found"} = json_response(conn, 404)
    end
  end

  describe "POST/GET /repos/:tenant_id/git/trees" do
    test "round-trips a tree with per-entry urls by type", %{conn: conn} do
      blob_conn =
        conn
        |> authed(write_token())
        |> put_req_header("content-type", "application/json")
        |> post("/repos/#{@tenant_id}/git/blobs", %{
          "content" => Base.encode64("file contents"),
          "encoding" => "base64"
        })

      %{"sha" => blob_sha} = json_response(blob_conn, 201)

      tree_conn =
        conn
        |> authed(write_token())
        |> put_req_header("content-type", "application/json")
        |> post("/repos/#{@tenant_id}/git/trees", %{
          "tree" => [
            %{"path" => "file.txt", "mode" => "100644", "sha" => blob_sha, "type" => "blob"}
          ]
        })

      body = json_response(tree_conn, 201)
      assert [entry] = body["tree"]
      assert entry["path"] == "file.txt"
      assert entry["type"] == "blob"
      assert String.ends_with?(entry["url"], "/repos/#{@tenant_id}/git/blobs/#{blob_sha}")

      show_conn =
        conn
        |> authed(read_token())
        |> get("/repos/#{@tenant_id}/git/trees/#{body["sha"]}")

      assert json_response(show_conn, 200) == body
    end
  end

  describe "POST/GET /repos/:tenant_id/git/commits" do
    test "creates and fetches a commit with tree/parent urls", %{conn: conn} do
      tree_conn =
        conn
        |> authed(write_token())
        |> put_req_header("content-type", "application/json")
        |> post("/repos/#{@tenant_id}/git/trees", %{"tree" => []})

      %{"sha" => tree_sha} = json_response(tree_conn, 201)

      commit_conn =
        conn
        |> authed(write_token())
        |> put_req_header("content-type", "application/json")
        |> post("/repos/#{@tenant_id}/git/commits", %{
          "tree" => tree_sha,
          "parents" => [],
          "message" => "Initial commit",
          "author" => %{
            "name" => "Test",
            "email" => "test@example.com",
            "date" => "2024-01-01T00:00:00Z"
          }
        })

      body = json_response(commit_conn, 201)
      assert body["message"] == "Initial commit"
      assert body["tree"]["sha"] == tree_sha
      assert String.ends_with?(body["tree"]["url"], "/repos/#{@tenant_id}/git/trees/#{tree_sha}")
      assert body["parents"] == []

      show_conn =
        conn
        |> authed(read_token())
        |> get("/repos/#{@tenant_id}/git/commits/#{body["sha"]}")

      assert json_response(show_conn, 200) == body
    end

    test "defaults committer to the author, as gitrest does", %{conn: conn} do
      # ICreateCommitParams has no committer field, so clients never send one and
      # the server must synthesize it. gitrest uses the author verbatim
      # (isomorphicgitManager.ts createCommitCore, isomorphicgitConversions.ts),
      # including the author's date — not a fresh server timestamp.
      tree_conn =
        conn
        |> authed(write_token())
        |> put_req_header("content-type", "application/json")
        |> post("/repos/#{@tenant_id}/git/trees", %{"tree" => []})

      %{"sha" => tree_sha} = json_response(tree_conn, 201)

      author = %{
        "name" => "Test",
        "email" => "test@example.com",
        "date" => "2024-01-01T00:00:00Z"
      }

      body =
        build_conn()
        |> authed(write_token())
        |> put_req_header("content-type", "application/json")
        |> post("/repos/#{@tenant_id}/git/commits", %{
          "tree" => tree_sha,
          "parents" => [],
          "message" => "authored",
          "author" => author
        })
        |> json_response(201)

      assert body["author"] == author
      assert body["committer"] == author

      # ...and it round-trips, rather than only being right on the create response.
      fetched =
        build_conn()
        |> authed(read_token())
        |> get("/repos/#{@tenant_id}/git/commits/#{body["sha"]}")
        |> json_response(200)

      assert fetched["committer"] == author
    end

    test "still honours an explicit committer when one is sent", %{conn: conn} do
      tree_conn =
        conn
        |> authed(write_token())
        |> put_req_header("content-type", "application/json")
        |> post("/repos/#{@tenant_id}/git/trees", %{"tree" => []})

      %{"sha" => tree_sha} = json_response(tree_conn, 201)

      committer = %{
        "name" => "Committer",
        "email" => "committer@example.com",
        "date" => "2024-02-02T00:00:00Z"
      }

      body =
        build_conn()
        |> authed(write_token())
        |> put_req_header("content-type", "application/json")
        |> post("/repos/#{@tenant_id}/git/commits", %{
          "tree" => tree_sha,
          "parents" => [],
          "message" => "explicitly committed",
          "author" => %{
            "name" => "Test",
            "email" => "test@example.com",
            "date" => "2024-01-01T00:00:00Z"
          },
          "committer" => committer
        })
        |> json_response(201)

      assert body["committer"] == committer
    end
  end

  describe "GET /repos/:tenant_id/commits" do
    # Historian's commit-history endpoint, which the official Routerlicious
    # driver calls from getVersions (services-client/src/historian.ts).
    # Note: not under /git — the driver's storageUrl is `/repos/:tenant_id`.

    defp create_commit!(conn, tree_sha, parents, message) do
      commit_conn =
        conn
        |> authed(write_token())
        |> put_req_header("content-type", "application/json")
        |> post("/repos/#{@tenant_id}/git/commits", %{
          "tree" => tree_sha,
          "parents" => parents,
          "message" => message,
          "author" => %{
            "name" => "Test",
            "email" => "test@example.com",
            "date" => "2024-01-01T00:00:00Z"
          }
        })

      json_response(commit_conn, 201)["sha"]
    end

    defp seed_history!(conn) do
      tree_conn =
        conn
        |> authed(write_token())
        |> put_req_header("content-type", "application/json")
        |> post("/repos/#{@tenant_id}/git/trees", %{"tree" => []})

      %{"sha" => tree_sha} = json_response(tree_conn, 201)

      first = create_commit!(conn, tree_sha, [], "first")
      second = create_commit!(conn, tree_sha, [first], "second")
      third = create_commit!(conn, tree_sha, [second], "third")

      {tree_sha, [third, second, first]}
    end

    test "walks first parents newest-first and shapes them as ICommitDetails",
         %{conn: conn} do
      {tree_sha, [third, second, _first] = all} = seed_history!(conn)

      body =
        conn
        |> authed(read_token())
        |> get("/repos/#{@tenant_id}/commits", %{"sha" => third, "count" => "10"})
        |> json_response(200)

      assert Enum.map(body, & &1["sha"]) == all

      [newest | _] = body
      assert Map.keys(newest) |> Enum.sort() == ["commit", "parents", "sha", "url"]
      assert String.ends_with?(newest["url"], "/repos/#{@tenant_id}/git/commits/#{third}")
      assert newest["commit"]["url"] == newest["url"]
      assert newest["commit"]["message"] == "third"
      assert newest["commit"]["author"]["name"] == "Test"
      assert newest["commit"]["tree"]["sha"] == tree_sha

      # The details view must agree with the object view for the same commit.
      object =
        build_conn()
        |> authed(read_token())
        |> get("/repos/#{@tenant_id}/git/commits/#{third}")
        |> json_response(200)

      assert newest["commit"]["committer"] == object["committer"]
      assert newest["commit"]["author"] == object["author"]
      assert newest["commit"]["tree"] == object["tree"]
      assert newest["parents"] == object["parents"]

      assert String.ends_with?(
               newest["commit"]["tree"]["url"],
               "/repos/#{@tenant_id}/git/trees/#{tree_sha}"
             )

      assert [%{"sha" => ^second, "url" => parent_url}] = newest["parents"]
      assert String.ends_with?(parent_url, "/repos/#{@tenant_id}/git/commits/#{second}")
    end

    test "honours count and defaults to 1", %{conn: conn} do
      {_tree_sha, [third, second, _first]} = seed_history!(conn)

      limited =
        conn
        |> authed(read_token())
        |> get("/repos/#{@tenant_id}/commits", %{"sha" => third, "count" => "2"})
        |> json_response(200)

      assert Enum.map(limited, & &1["sha"]) == [third, second]

      defaulted =
        conn
        |> authed(read_token())
        |> get("/repos/#{@tenant_id}/commits", %{"sha" => third})
        |> json_response(200)

      assert Enum.map(defaulted, & &1["sha"]) == [third]
    end

    test "resolves a branch name through refs/heads before trying it as a sha",
         %{conn: conn} do
      {_tree_sha, [third | _]} = seed_history!(conn)
      branch = "doc-#{System.unique_integer([:positive])}"

      conn
      |> authed(write_token())
      |> put_req_header("content-type", "application/json")
      |> post("/repos/#{@tenant_id}/git/refs", %{
        "ref" => "refs/heads/#{branch}",
        "sha" => third
      })
      |> json_response(201)

      body =
        conn
        |> authed(read_token())
        |> get("/repos/#{@tenant_id}/commits", %{"sha" => branch, "count" => "1"})
        |> json_response(200)

      assert [%{"sha" => ^third}] = body
    end

    test "returns [] for an unknown sha rather than 404", %{conn: conn} do
      body =
        conn
        |> authed(read_token())
        |> get("/repos/#{@tenant_id}/commits", %{"sha" => "no-such-sha"})
        |> json_response(200)

      assert body == []
    end

    test "rejects a missing sha and a non-positive count", %{conn: conn} do
      assert %{"error" => _} =
               conn
               |> authed(read_token())
               |> get("/repos/#{@tenant_id}/commits")
               |> json_response(400)

      assert %{"error" => _} =
               conn
               |> authed(read_token())
               |> get("/repos/#{@tenant_id}/commits", %{"sha" => "x", "count" => "0"})
               |> json_response(400)
    end

    test "requires doc:read", %{conn: conn} do
      assert conn
             |> get("/repos/#{@tenant_id}/commits", %{"sha" => "x"})
             |> json_response(401)
    end
  end

  describe "POST/GET/PATCH /repos/:tenant_id/git/refs" do
    test "creates, lists, shows, and updates a ref", %{conn: conn} do
      branch = "main-#{System.unique_integer([:positive])}"

      tree_conn =
        conn
        |> authed(write_token())
        |> put_req_header("content-type", "application/json")
        |> post("/repos/#{@tenant_id}/git/trees", %{"tree" => []})

      %{"sha" => tree_sha} = json_response(tree_conn, 201)

      commit_conn =
        conn
        |> authed(write_token())
        |> put_req_header("content-type", "application/json")
        |> post("/repos/#{@tenant_id}/git/commits", %{
          "tree" => tree_sha,
          "parents" => [],
          "message" => "c1 #{branch}",
          "author" => %{
            "name" => "T",
            "email" => "t@example.com",
            "date" => "2024-01-01T00:00:00Z"
          }
        })

      %{"sha" => commit_sha} = json_response(commit_conn, 201)

      ref_conn =
        conn
        |> authed(write_token())
        |> put_req_header("content-type", "application/json")
        |> post("/repos/#{@tenant_id}/git/refs", %{
          "ref" => "refs/heads/#{branch}",
          "sha" => commit_sha
        })

      ref_body = json_response(ref_conn, 201)
      assert ref_body["ref"] == "refs/heads/#{branch}"
      assert ref_body["object"]["sha"] == commit_sha
      assert ref_body["object"]["type"] == "commit"
      # "refs/" prefix stripped from the ref URL
      assert String.ends_with?(ref_body["url"], "/repos/#{@tenant_id}/git/refs/heads/#{branch}")

      show_conn =
        conn
        |> authed(read_token())
        |> get("/repos/#{@tenant_id}/git/refs/heads/#{branch}")

      assert json_response(show_conn, 200) == ref_body

      list_conn =
        conn
        |> authed(read_token())
        |> get("/repos/#{@tenant_id}/git/refs")

      # The tenant's ref store is shared with other tests in this suite (it's
      # backed by persistent storage), so assert this ref is present rather
      # than asserting the full list contents.
      assert ref_body in json_response(list_conn, 200)

      # PATCH updates an existing ref (upsert semantics tested separately below)
      patch_conn =
        conn
        |> authed(write_token())
        |> put_req_header("content-type", "application/json")
        |> patch("/repos/#{@tenant_id}/git/refs/heads/#{branch}", %{"sha" => commit_sha})

      assert json_response(patch_conn, 200) == ref_body
    end

    test "PATCH upserts (creates) a ref that doesn't exist yet", %{conn: conn} do
      branch = "upsert-branch-#{System.unique_integer([:positive])}"

      tree_conn =
        conn
        |> authed(write_token())
        |> put_req_header("content-type", "application/json")
        |> post("/repos/#{@tenant_id}/git/trees", %{"tree" => []})

      %{"sha" => tree_sha} = json_response(tree_conn, 201)

      commit_conn =
        conn
        |> authed(write_token())
        |> put_req_header("content-type", "application/json")
        |> post("/repos/#{@tenant_id}/git/commits", %{
          "tree" => tree_sha,
          "parents" => [],
          "message" => "c1 #{branch}",
          "author" => %{
            "name" => "T",
            "email" => "t@example.com",
            "date" => "2024-01-01T00:00:00Z"
          }
        })

      %{"sha" => commit_sha} = json_response(commit_conn, 201)

      patch_conn =
        conn
        |> authed(write_token())
        |> put_req_header("content-type", "application/json")
        |> patch("/repos/#{@tenant_id}/git/refs/heads/#{branch}", %{"sha" => commit_sha})

      body = json_response(patch_conn, 200)
      assert body["ref"] == "refs/heads/#{branch}"
      assert body["object"]["sha"] == commit_sha
    end
  end
end
