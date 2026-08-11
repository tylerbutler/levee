defmodule Levee.SpillwayTest do
  @moduledoc """
  Unit tests for `Levee.Spillway`, the Elixir bridge to spillway's
  Engine.IO/Socket.IO framing (`spillway/socketio`), `connect_document`
  protocol decision helpers (`spillway/connect_document`), the pure
  document-session decision logic (`spillway/session_logic`, `spillway/nack`),
  and the REST response-shape decisions (`spillway/rest`) used by
  `LeveeWeb.GitController`, `LeveeWeb.DocumentController`, and
  `LeveeWeb.DeltaController`.

  These exercise the bridge directly (no live socket/session runtime
  needed) so framing/decision regressions show up fast, independent of the
  live Routerlicious-driver conformance suite in
  `client/packages/levee-driver/test/integration/floodgate-routerlicious.test.ts`
  and the full-stack controller tests in
  `test/levee_web/controllers/{git,delta,document}_controller_test.exs`.
  """

  use ExUnit.Case, async: true

  alias Levee.Spillway

  describe "Engine.IO / Socket.IO framing" do
    test "encode_open builds the Engine.IO opening handshake packet" do
      packet = Spillway.encode_open("sid-123", 25_000, 20_000, 1_000_000)

      assert "0" <> json = packet
      assert {:ok, decoded} = Jason.decode(json)

      assert decoded == %{
               "sid" => "sid-123",
               "upgrades" => [],
               "pingInterval" => 25_000,
               "pingTimeout" => 20_000,
               "maxPayload" => 1_000_000
             }
    end

    test "encode_connect_ack builds the Socket.IO namespace-connect ack" do
      assert Spillway.encode_connect_ack("sid-123") == "40{\"sid\":\"sid-123\"}"
    end

    test "encode_pong returns the Engine.IO pong byte" do
      assert Spillway.encode_pong() == "3"
    end

    test "classify_frame recognizes Engine.IO ping/pong and Socket.IO connect" do
      assert Spillway.classify_frame("2") == :engine_ping
      assert Spillway.classify_frame("3") == :engine_pong
      assert Spillway.classify_frame("40") == :socket_connect
    end

    test "classify_frame decodes a Fluid event frame" do
      assert {:fluid_event, "connect_document", [payload]} =
               Spillway.classify_frame(~s(42["connect_document",{"id":"doc-1"}]))

      assert payload["id"] == "doc-1"
    end

    test "classify_frame reports unrecognized frames" do
      assert {:unrecognized, _reason} = Spillway.classify_frame("garbage")
    end

    test "encode_op enforces the Routerlicious-required two-argument shape" do
      frame = Spillway.encode_op("doc-1", [%{"sequenceNumber" => 1}])

      assert {:fluid_event, "op", [document_id, messages]} = Spillway.classify_frame(frame)
      assert document_id == "doc-1"
      assert messages == [%{"sequenceNumber" => 1}]
    end

    test "encode_signal round-trips a signal payload" do
      frame = Spillway.encode_signal(%{"clientId" => "c1"})

      assert {:fluid_event, "signal", [signal]} = Spillway.classify_frame(frame)
      assert signal == %{"clientId" => "c1"}
    end

    test "encode_connect_document_success/error round-trip payloads" do
      success_frame = Spillway.encode_connect_document_success(%{"clientId" => "c1"})

      assert {:fluid_event, "connect_document_success", [payload]} =
               Spillway.classify_frame(success_frame)

      assert payload == %{"clientId" => "c1"}

      error_frame = Spillway.encode_connect_document_error(%{"code" => 400})

      assert {:fluid_event, "connect_document_error", [payload]} =
               Spillway.classify_frame(error_frame)

      assert payload == %{"code" => 400}
    end
  end

  describe "connect_document protocol decisions" do
    test "parse_connect_request extracts tenant/document/token" do
      payload = %{"tenantId" => "tenant-a", "id" => "doc-a", "token" => "token-a"}

      assert {:ok, {"tenant-a", "doc-a", "token-a"}} = Spillway.parse_connect_request(payload)
    end

    test "parse_connect_request reports the first missing field" do
      payload = %{"tenantId" => "tenant-a", "token" => "token-a"}

      assert {:error, {:missing_field, "id"}} = Spillway.parse_connect_request(payload)
    end

    test "parse_connect_request rejects an empty string field" do
      payload = %{"tenantId" => "", "id" => "doc-a", "token" => "token-a"}

      assert {:error, {:missing_field, "tenantId"}} = Spillway.parse_connect_request(payload)
    end

    test "validate_mode_scope requires doc:write only for write mode" do
      assert :ok = Spillway.validate_mode_scope(%{"mode" => "write"}, ["doc:read", "doc:write"])

      assert {:error, :write_mode_without_write_scope} =
               Spillway.validate_mode_scope(%{"mode" => "write"}, ["doc:read"])
    end

    test "validate_mode_scope allows any scopes when mode is absent or not write" do
      assert :ok = Spillway.validate_mode_scope(%{}, [])
      assert :ok = Spillway.validate_mode_scope(%{"mode" => "read"}, [])
    end

    test "read_scope/write_scope expose spillway's Scope vocabulary" do
      assert Spillway.read_scope() == "doc:read"
      assert Spillway.write_scope() == "doc:write"
    end
  end

  describe "negotiate_features/2" do
    test "server true + client absent advertises true" do
      assert Spillway.negotiate_features(%{"submitSignals" => true}, %{}) == %{
               "submitSignals" => true
             }
    end

    test "server true + client explicitly declines yields false" do
      assert Spillway.negotiate_features(%{"submitSignals" => true}, %{"submitSignals" => false}) ==
               %{"submitSignals" => false}
    end

    test "server true + client agrees stays true" do
      assert Spillway.negotiate_features(%{"submitSignals" => true}, %{"submitSignals" => true}) ==
               %{"submitSignals" => true}
    end

    test "server false always yields server value regardless of client" do
      assert Spillway.negotiate_features(%{"submitSignals" => false}, %{"submitSignals" => true}) ==
               %{"submitSignals" => false}
    end

    test "negotiates independently across multiple features" do
      server = %{"a" => true, "b" => true, "c" => false}
      client = %{"a" => false, "c" => true}

      assert Spillway.negotiate_features(server, client) == %{
               "a" => false,
               "b" => true,
               "c" => false
             }
    end
  end

  describe "determine_signal_recipients/5" do
    test "targeted_clients takes priority, excluding sender and unknown ids" do
      assert Spillway.determine_signal_recipients(
               "sender",
               ["sender", "c1", "c2", "unknown"],
               ["c1"],
               "c2",
               ["sender", "c1", "c2"]
             ) == ["c1", "c2"]
    end

    test "ignored_clients excludes ignored ids and the sender" do
      assert Spillway.determine_signal_recipients(
               "sender",
               nil,
               ["c1"],
               nil,
               ["sender", "c1", "c2", "c3"]
             ) == ["c2", "c3"]
    end

    test "single_target sends only to that target when valid" do
      assert Spillway.determine_signal_recipients(
               "sender",
               nil,
               nil,
               "c2",
               ["sender", "c1", "c2"]
             ) == ["c2"]
    end

    test "single_target returns empty list when target is the sender" do
      assert Spillway.determine_signal_recipients(
               "sender",
               nil,
               nil,
               "sender",
               ["sender", "c1"]
             ) == []
    end

    test "single_target returns empty list when target is unknown" do
      assert Spillway.determine_signal_recipients(
               "sender",
               nil,
               nil,
               "unknown",
               ["sender", "c1"]
             ) == []
    end

    test "broadcasts to all except sender when no targeting options given" do
      assert Spillway.determine_signal_recipients(
               "sender",
               nil,
               nil,
               nil,
               ["sender", "c1", "c2"]
             ) == ["c1", "c2"]
    end

    test "treats empty list/string targeting options as absent (broadcast)" do
      assert Spillway.determine_signal_recipients(
               "sender",
               [],
               [],
               "",
               ["sender", "c1", "c2"]
             ) == ["c1", "c2"]
    end
  end

  describe "build_sequenced_op/1" do
    test "builds the wire-format map with all sequenced-op fields" do
      params =
        {:sequenced_op_params, "client-1", 42, 40, 7, 41, "op", %{"foo" => "bar"}, nil,
         1_700_000_000}

      op = Spillway.build_sequenced_op(params)

      assert op == %{
               "clientId" => "client-1",
               "sequenceNumber" => 42,
               "minimumSequenceNumber" => 40,
               "clientSequenceNumber" => 7,
               "referenceSequenceNumber" => 41,
               "type" => "op",
               "contents" => %{"foo" => "bar"},
               "metadata" => nil,
               "timestamp" => 1_700_000_000
             }
    end
  end

  describe "nack_unknown_client/1" do
    test "builds a nack tuple with no operation, sequence -1, and a bad-request content" do
      assert {:nack, :none, -1,
              {:nack_content, 400, :bad_request_error, "Unknown client: client-1", :none}} =
               Spillway.nack_unknown_client("client-1")
    end

    test "embeds the given client id in the message" do
      assert {:nack, :none, -1, {:nack_content, 400, :bad_request_error, message, :none}} =
               Spillway.nack_unknown_client("abc-123")

      assert message == "Unknown client: abc-123"
    end
  end

  describe "REST response-shape decisions (spillway/rest)" do
    test "base_url omits the default port for http/https" do
      assert Spillway.base_url("http", "example.test", 80) == "http://example.test"
      assert Spillway.base_url("https", "example.test", 443) == "https://example.test"
      assert Spillway.base_url("http", "localhost", 4000) == "http://localhost:4000"
    end

    test "blob_url/tree_url/commit_url build git object urls" do
      assert Spillway.blob_url("http://localhost:4000", "tenant1", "sha1") ==
               "http://localhost:4000/repos/tenant1/git/blobs/sha1"

      assert Spillway.tree_url("http://localhost:4000", "tenant1", "sha1") ==
               "http://localhost:4000/repos/tenant1/git/trees/sha1"

      assert Spillway.commit_url("http://localhost:4000", "tenant1", "sha1") ==
               "http://localhost:4000/repos/tenant1/git/commits/sha1"
    end

    test "ref_url strips the refs/ prefix" do
      assert Spillway.ref_url("http://localhost:4000", "tenant1", "refs/heads/main") ==
               "http://localhost:4000/repos/tenant1/git/refs/heads/main"
    end

    test "build_ref_path joins wildcard segments" do
      assert Spillway.build_ref_path(["heads", "main"]) == "refs/heads/main"
    end

    test "format_blob_response builds the full blob wire shape" do
      assert Spillway.format_blob_response(
               "http://localhost:4000",
               "tenant1",
               "sha1",
               5,
               "aGVsbG8="
             ) ==
               %{
                 "sha" => "sha1",
                 "size" => 5,
                 "content" => "aGVsbG8=",
                 "encoding" => "base64",
                 "url" => "http://localhost:4000/repos/tenant1/git/blobs/sha1"
               }
    end

    test "format_tree_response builds per-entry urls keyed by entry type" do
      entries = [
        {"file.txt", "100644", "blobsha", "blob"},
        {"subdir", "040000", "treesha", "tree"},
        {"weird", "120000", "othersha", "symlink"}
      ]

      response =
        Spillway.format_tree_response("http://localhost:4000", "tenant1", "roottree", entries)

      assert response["sha"] == "roottree"
      assert response["url"] == "http://localhost:4000/repos/tenant1/git/trees/roottree"

      assert response["tree"] == [
               %{
                 "path" => "file.txt",
                 "mode" => "100644",
                 "sha" => "blobsha",
                 "type" => "blob",
                 "url" => "http://localhost:4000/repos/tenant1/git/blobs/blobsha"
               },
               %{
                 "path" => "subdir",
                 "mode" => "040000",
                 "sha" => "treesha",
                 "type" => "tree",
                 "url" => "http://localhost:4000/repos/tenant1/git/trees/treesha"
               },
               %{
                 "path" => "weird",
                 "mode" => "120000",
                 "sha" => "othersha",
                 "type" => "symlink",
                 "url" => nil
               }
             ]
    end

    test "format_commit_response builds tree/parent object shapes" do
      response =
        Spillway.format_commit_response(
          "http://localhost:4000",
          "tenant1",
          "commitsha",
          "treesha",
          ["parent1", "parent2"],
          "Initial commit",
          %{"name" => "Test", "email" => "test@example.com"},
          %{"name" => "Test", "email" => "test@example.com"}
        )

      assert response["sha"] == "commitsha"
      assert response["message"] == "Initial commit"
      assert response["author"] == %{"name" => "Test", "email" => "test@example.com"}
      assert response["url"] == "http://localhost:4000/repos/tenant1/git/commits/commitsha"

      assert response["tree"] == %{
               "sha" => "treesha",
               "url" => "http://localhost:4000/repos/tenant1/git/trees/treesha"
             }

      assert response["parents"] == [
               %{
                 "sha" => "parent1",
                 "url" => "http://localhost:4000/repos/tenant1/git/commits/parent1"
               },
               %{
                 "sha" => "parent2",
                 "url" => "http://localhost:4000/repos/tenant1/git/commits/parent2"
               }
             ]
    end

    test "format_ref_response builds the ref wire shape" do
      response =
        Spillway.format_ref_response(
          "http://localhost:4000",
          "tenant1",
          "refs/heads/main",
          "commitsha"
        )

      assert response == %{
               "ref" => "refs/heads/main",
               "object" => %{
                 "sha" => "commitsha",
                 "type" => "commit",
                 "url" => "http://localhost:4000/repos/tenant1/git/commits/commitsha"
               },
               "url" => "http://localhost:4000/repos/tenant1/git/refs/heads/main"
             }
    end

    test "format_document_response builds the document metadata wire shape" do
      assert Spillway.format_document_response("doc-1", "tenant1", 5) == %{
               "id" => "doc-1",
               "tenantId" => "tenant1",
               "sequenceNumber" => 5
             }
    end

    test "session_info builds the session-discovery wire shape" do
      assert Spillway.session_info("http://localhost:4000", "tenant1", "doc-1", true) == %{
               "ordererUrl" => "http://localhost:4000/socket",
               "historianUrl" => "http://localhost:4000/repos/tenant1",
               "deltaStreamUrl" => "http://localhost:4000/deltas/tenant1/doc-1",
               "isSessionAlive" => true,
               "isSessionActive" => true
             }

      assert Spillway.session_info("http://localhost:4000", "tenant1", "doc-1", false)[
               "isSessionAlive"
             ] == false
    end

    test "requires_data_field?/1 is true only for join/leave" do
      assert Spillway.requires_data_field?("join")
      assert Spillway.requires_data_field?("leave")
      refute Spillway.requires_data_field?("op")
      refute Spillway.requires_data_field?("summarize")
    end

    test "format_delta_message omits data for regular ops" do
      message =
        Spillway.format_delta_message(
          1,
          1,
          0,
          "client-1",
          0,
          "op",
          %{"a" => 1},
          nil,
          1_700_000_000,
          nil
        )

      refute Map.has_key?(message, "data")
      assert message["type"] == "op"
      assert message["contents"] == %{"a" => 1}
    end

    test "format_delta_message includes data for join/leave" do
      message =
        Spillway.format_delta_message(
          2,
          -1,
          0,
          nil,
          0,
          "join",
          %{"clientId" => "c1"},
          nil,
          1_700_000_000,
          Jason.encode!(%{"clientId" => "c1"})
        )

      assert message["data"] == Jason.encode!(%{"clientId" => "c1"})
    end
  end
end
