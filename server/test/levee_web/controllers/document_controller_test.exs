defmodule LeveeWeb.DocumentControllerTest do
  use LeveeWeb.ConnCase

  alias Levee.Auth.JWT
  alias Levee.Auth.TenantSecrets
  alias Levee.Storage

  @tenant_id "protocol-test-tenant"
  @user_id "test-user"

  setup do
    {:ok, _} = Application.ensure_all_started(:levee)

    TenantSecrets.register_tenant(@tenant_id, "test-secret-key-for-protocol-tests")
    on_exit(fn -> TenantSecrets.unregister_tenant(@tenant_id) end)

    :ok
  end

  defp generate_token(document_id) do
    {:ok, token} =
      JWT.generate_test_token(@tenant_id, document_id, @user_id,
        scopes: ["doc:read", "doc:write", "summary:write"]
      )

    token
  end

  describe "POST /documents/:tenant_id with .protocol subtree" do
    test "preserves .protocol subtree in initial summary", %{conn: conn} do
      # Build a Fluid-style initial summary with .app and .protocol subtrees
      # Type 1 = SummaryTree, Type 2 = SummaryBlob
      summary = %{
        "type" => 1,
        "tree" => %{
          ".app" => %{
            "type" => 1,
            "tree" => %{
              ".channels" => %{
                "type" => 1,
                "tree" => %{
                  "root" => %{"type" => 2, "content" => ~s({"key":"value"})}
                }
              }
            }
          },
          ".protocol" => %{
            "type" => 1,
            "tree" => %{
              "attributes" => %{
                "type" => 2,
                "content" => ~s({"minimumSequenceNumber":0,"sequenceNumber":0,"term":1})
              },
              "quorumMembers" => %{
                "type" => 2,
                "content" => "[]"
              },
              "quorumProposals" => %{
                "type" => 2,
                "content" => "[]"
              },
              "quorumValues" => %{
                "type" => 2,
                "content" => "[]"
              }
            }
          }
        }
      }

      document_id = "protocol-doc-#{System.unique_integer([:positive])}"
      token = generate_token(document_id)

      # Create the document with the initial summary
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> put_req_header("content-type", "application/json")
        |> post("/documents/#{@tenant_id}", %{
          "id" => document_id,
          "summary" => summary,
          "sequenceNumber" => 0
        })

      assert response(conn, 201)

      # Read back the ref → commit → tree to verify .protocol is stored
      {:ok, ref} = Storage.get_ref(@tenant_id, "refs/heads/#{document_id}")
      {:ok, commit} = Storage.get_commit(@tenant_id, ref.sha)
      {:ok, root_tree} = Storage.get_tree(@tenant_id, commit.tree)

      # Find the .protocol entry in the root tree
      protocol_entry =
        Enum.find(root_tree.tree, fn entry -> entry.path == ".protocol" end)

      assert protocol_entry != nil, "Root tree should contain a .protocol entry"
      assert protocol_entry.type == "tree"

      # Read the .protocol tree and verify all 4 blobs are present
      {:ok, protocol_tree} = Storage.get_tree(@tenant_id, protocol_entry.sha)

      protocol_paths =
        protocol_tree.tree
        |> Enum.map(& &1.path)
        |> Enum.sort()

      assert protocol_paths == ["attributes", "quorumMembers", "quorumProposals", "quorumValues"]

      # Verify each blob is readable and contains expected content
      for entry <- protocol_tree.tree do
        {:ok, blob} = Storage.get_blob(@tenant_id, entry.sha)
        assert is_binary(blob.content), "Blob at #{entry.path} should be readable"
      end

      # Spot-check the attributes blob content
      attributes_entry =
        Enum.find(protocol_tree.tree, fn e -> e.path == "attributes" end)

      {:ok, attributes_blob} = Storage.get_blob(@tenant_id, attributes_entry.sha)
      {:ok, attributes} = Jason.decode(attributes_blob.content)
      assert attributes["minimumSequenceNumber"] == 0
      assert attributes["sequenceNumber"] == 0
    end

    test ".app contents are unwrapped to root level", %{conn: conn} do
      summary = %{
        "type" => 1,
        "tree" => %{
          ".app" => %{
            "type" => 1,
            "tree" => %{
              ".channels" => %{
                "type" => 1,
                "tree" => %{
                  "root" => %{"type" => 2, "content" => "channel-data"}
                }
              },
              ".metadata" => %{"type" => 2, "content" => "meta-data"}
            }
          },
          ".protocol" => %{
            "type" => 1,
            "tree" => %{
              "attributes" => %{"type" => 2, "content" => "attrs"}
            }
          }
        }
      }

      document_id = "unwrap-doc-#{System.unique_integer([:positive])}"
      token = generate_token(document_id)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> put_req_header("content-type", "application/json")
        |> post("/documents/#{@tenant_id}", %{
          "id" => document_id,
          "summary" => summary,
          "sequenceNumber" => 0
        })

      assert response(conn, 201)

      {:ok, ref} = Storage.get_ref(@tenant_id, "refs/heads/#{document_id}")
      {:ok, commit} = Storage.get_commit(@tenant_id, ref.sha)
      {:ok, root_tree} = Storage.get_tree(@tenant_id, commit.tree)

      root_paths =
        root_tree.tree
        |> Enum.map(& &1.path)
        |> Enum.sort()

      # .app children (.channels, .metadata) should be at root alongside .protocol
      assert ".channels" in root_paths
      assert ".metadata" in root_paths
      assert ".protocol" in root_paths
      # .app itself should NOT be at root (it's unwrapped)
      refute ".app" in root_paths
    end
  end
end
