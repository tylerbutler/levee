/**
 * Routerlicious driver compatibility checks for Sluice.
 *
 * These tests define the compatibility baseline: an unmodified official
 * Routerlicious driver should be able to use Sluice's Socket.IO/dewdrop
 * realtime endpoint plus its REST document/storage surface. All networked
 * tests are opt-in (`SLUICE_ROUTERLICIOUS_COMPAT=1`) because neither Sluice
 * nor Levee's proxy of it is part of the default test run.
 *
 * Live-target matrix — point the same suite at either backend by env, run
 * twice (see `sluice-target.ts` for the full var list and run instructions):
 *
 *   Sluice direct:  SLUICE_HTTP_URL=http://localhost:3000 SLUICE_SOCKET_URL=http://localhost:3000 (defaults)
 *   Levee proxy:    SLUICE_HTTP_URL=http://localhost:4000 SLUICE_SOCKET_URL=http://localhost:4000
 *
 * Both targets expose their own HTTP/WS listener today: Levee via
 * `server/lib/levee_web/socket_io_websock.ex` plus the REST controllers in
 * `server/lib/levee_web/controllers/`, and the standalone `sluice/` Gleam
 * service via Mist, started by `serve/1`/`main()` in `server/sluice/src/sluice.gleam`.
 * Standalone Sluice's REST surface is a smaller subset than Levee's proxy,
 * though — it implements document create, deltas catch-up, and git
 * blob/tree/commit object storage, but not session discovery or git refs
 * (see `server/sluice/src/sluice.gleam`'s `rest/2` route match). Tests that
 * need those routes gate on `isLeveeProxyTarget` and pair with an
 * `it.todo` explaining the standalone-only gap, rather than skipping
 * silently or assuming the route is universally unimplemented.
 */

import type { IConnected } from "@fluidframework/protocol-definitions";
import { describe, expect, it } from "vitest";
import { uniqueDocId } from "./helpers.js";
import {
	CONNECTED_RESPONSE_REQUIRED_FIELDS,
	SLUICE_AUTH_SCOPES,
	SLUICE_REQUIRED_SCOPES,
	SLUICE_REST_ENDPOINTS,
	SLUICE_SOCKET_EVENTS,
} from "./sluice-contract.js";
import {
	createBlobTreeCommit,
	createSluiceResolvedUrl,
	createSluiceServiceFactory,
	createSluiceTestClient,
	isLeveeProxyTarget,
	isSluiceRunning,
	SLUICE_HTTP_URL,
	SLUICE_SOCKET_URL,
	SLUICE_TARGET_LABEL,
	SLUICE_TENANT_ID,
	sluiceFetch,
} from "./sluice-target.js";

const sluiceAvailable = await isSluiceRunning();

const testClient = createSluiceTestClient("routerlicious-compat-user");

describe("Sluice Routerlicious compatibility contract", () => {
	it("builds a Routerlicious resolved URL targeting Sluice endpoints", () => {
		const documentId = "compat-doc";
		const resolvedUrl = createSluiceResolvedUrl(documentId);

		expect(resolvedUrl.type).toBe("fluid");
		expect(resolvedUrl.id).toBe(documentId);
		expect(resolvedUrl.endpoints["ordererUrl"]).toBe(SLUICE_HTTP_URL);
		expect(resolvedUrl.endpoints["deltaStreamUrl"]).toBe(SLUICE_SOCKET_URL);
		expect(resolvedUrl.endpoints["deltaStorageUrl"]).toBe(
			`${SLUICE_HTTP_URL}/documents/${SLUICE_TENANT_ID}/${documentId}/deltas`,
		);
		expect(resolvedUrl.endpoints["storageUrl"]).toBe(
			`${SLUICE_HTTP_URL}/repos/${SLUICE_TENANT_ID}`,
		);
	});

	it("reports which live target (Sluice direct or Levee proxy) this run is configured for", () => {
		expect(["sluice-direct", "levee-proxy"]).toContain(SLUICE_TARGET_LABEL);
	});

	it.runIf(sluiceAvailable && isLeveeProxyTarget)(
		"connects an unmodified Routerlicious delta stream to Sluice",
		{ timeout: 30_000 },
		async () => {
			const documentId = uniqueDocId("sluice-routerlicious");
			const factory = createSluiceServiceFactory();
			const resolvedUrl = createSluiceResolvedUrl(documentId);
			const service = await factory.createDocumentService(resolvedUrl);

			const connection = await service.connectToDeltaStream(testClient);

			expect(connection.clientId).toBeDefined();
			expect(connection.mode).toBe("write");

			connection.dispose();
		},
	);

	it.todo(
		"[sluice-direct target] delta-stream connect — the official driver's " +
			"socket.io-client performs its handshake against the default " +
			"Engine.IO/Socket.IO path (`/socket.io/...`), but standalone " +
			"Sluice's `beryl/transport/mist` upgrades only exact-path raw " +
			'WebSocket requests at `/socket` (`mist_transport.default_config("/socket")` ' +
			"in `server/sluice.gleam`), with no Socket.IO handshake/framing " +
			"layer. Confirmed failing live against `gleam run` on port 3000 " +
			"with `websocket error: TransportError`. Covered above for the " +
			"levee-proxy target, which speaks Socket.IO via " +
			"`server/lib/levee_web/socket_io_websock.ex`.",
	);

	it.todo(
		"official createContainer() over the levee-proxy target — currently " +
			"blocked by an auth scheme mismatch, not just a missing route: " +
			"`RouterliciousDocumentServiceFactory.createContainer`'s orderer " +
			"REST calls always send `Authorization: Basic <jwt>` " +
			"(`RouterliciousOrdererRestWrapper.load` in " +
			"`@fluidframework/routerlicious-driver`'s restWrapper.ts hard-codes " +
			"the `Basic` scheme), but Levee's auth plug only accepts `Bearer " +
			"<token>` (`server/lib/levee_web/plugs/auth.ex#extract_token`), so " +
			"every such call 401s with 'Invalid Authorization header format'. " +
			"Confirmed live against the running Levee proxy on port 4000 (with " +
			"`enableRestLess: false` set to rule out the separate RestLess-body " +
			"encoding issue also discovered while building this test — see " +
			"`createSluiceServiceFactory` in `sluice-target.ts`). Fixing this " +
			"needs a runtime change (either Levee accepting `Basic` for this " +
			"route, or a documented reason official Routerlicious clients " +
			"can't create documents against Levee), which is out of scope for " +
			"a conformance-test-only change. `createMinimalCombinedSummary()` " +
			"in `sluice-target.ts` is ready to drive this once unblocked.",
	);

	it.todo(
		"[sluice-direct target] official createContainer() — the driver's " +
			"create path POSTs to `/documents/:tenantId` (two path segments, " +
			"documentId assigned by the server; see " +
			"`RouterliciousDocumentServiceFactory.createContainer` in " +
			"`@fluidframework/routerlicious-driver`), but standalone Sluice's " +
			"only document-create route is the three-segment " +
			"`POST /documents/:tenant/:doc` in `server/sluice/src/sluice.gleam`'s " +
			"`rest/2`, which requires the client to choose the id up front. " +
			"Also blocked by the same `Basic` vs `Bearer` Authorization-scheme " +
			"mismatch noted in the levee-proxy todo above.",
	);
});

describe("Sluice contract — connect handshake shape", () => {
	it("connect_document_success payload satisfies IConnected's required fields", () => {
		// Minimal-but-real IConnected literal. The `satisfies` check below is a
		// compile-time enforcement that Sluice's join-response builder
		// (`sluice/document_channel.gleam`'s `JoinOk` reply) must eventually
		// produce every field the official driver requires — this fails to
		// typecheck if `@fluidframework/protocol-definitions` adds a new
		// required field that Sluice hasn't accounted for.
		const minimalConnected = {
			claims: {
				documentId: "doc",
				tenantId: "fluid",
				scopes: [SLUICE_AUTH_SCOPES.docRead, SLUICE_AUTH_SCOPES.docWrite],
				user: { id: "u" },
				ver: "1.0",
			},
			clientId: "client-1",
			existing: true,
			maxMessageSize: 16 * 1024,
			initialMessages: [],
			initialSignals: [],
			initialClients: [],
			version: "0.1.0",
			supportedVersions: ["0.1.0"],
			serviceConfiguration: {
				maxMessageSize: 16 * 1024,
				blockSize: 1024,
			},
			mode: "write",
		} satisfies IConnected;

		for (const field of CONNECTED_RESPONSE_REQUIRED_FIELDS) {
			expect(minimalConnected).toHaveProperty(field);
		}
	});

	it.todo(
		"Sluice's connect_document response includes claims decoded from the presented JWT",
	);

	it.todo(
		"Sluice's connect_document response reports existing:false for a brand-new document",
	);
});

describe("Sluice contract — socket event vocabulary", () => {
	// NOTE: this only pins the *event name strings* Sluice's dewdrop/events.gleam
	// exposes. It is not behavior coverage — actual signal fan-out semantics
	// (ordering, no-sequencing guarantee, delivery to all connected clients)
	// are exercised (as a todo, pending live harness support) below in
	// "Sluice contract — operation submission, sequencing & fan-out".
	it("uses the dewdrop/events.gleam event names for op/signal/summary flows", () => {
		expect(SLUICE_SOCKET_EVENTS.connectDocument).toBe("connect_document");
		expect(SLUICE_SOCKET_EVENTS.connectDocumentSuccess).toBe(
			"connect_document_success",
		);
		expect(SLUICE_SOCKET_EVENTS.submitOp).toBe("submitOp");
		expect(SLUICE_SOCKET_EVENTS.op).toBe("op");
		expect(SLUICE_SOCKET_EVENTS.submitSignal).toBe("submitSignal");
		expect(SLUICE_SOCKET_EVENTS.signal).toBe("signal");
		expect(SLUICE_SOCKET_EVENTS.nack).toBe("nack");
		expect(SLUICE_SOCKET_EVENTS.submitSummary).toBe("submitSummary");
		expect(SLUICE_SOCKET_EVENTS.summaryAck).toBe("summaryAck");
	});
});

describe.todo("Sluice contract — operation submission, sequencing & fan-out", () => {
	it.todo(
		"assigns monotonically increasing sequenceNumber across clients on a document",
	);
	it.todo(
		"fans out an accepted op to every connected client, including the submitter",
	);
	it.todo(
		"nacks an op submitted with a stale/mismatched reference sequence number",
	);
	it.todo(
		"fans out submitSignal payloads to every connected client without sequencing " +
			"(behavior coverage, not just the event-name vocabulary asserted in " +
			"'Sluice contract — socket event vocabulary' above)",
	);
});

describe.todo("Sluice contract — SharedMap/DDS sync via Loader/fluid-static", () => {
	// Not yet added: exercising this requires either a Fluid `Loader` +
	// `codeLoader`/container-runtime-factory setup (the driver package has
	// no dependency on `@fluidframework/container-loader` today — see
	// `client/packages/levee-driver/package.json`) or reusing
	// `@tylerbu/levee-client`'s fluid-static `LeveeClient` wrapper, which
	// already exercises this exact scenario end-to-end (see
	// `createContainer`/`getContainer` + `testMap` round-trip in
	// `client/packages/levee-client/test/integration/client.test.ts`).
	// Once the official create-container path above is unblocked for
	// both targets (or a lightweight Loader harness is added here without
	// pulling in a new dependency), add:
	it.todo(
		"two Loader-backed containers converge on a SharedMap value set by one client",
	);
	it.todo(
		"a client joining after a SharedMap op sees the same state after loading the snapshot",
	);
});

describe.todo("Sluice contract — summaries", () => {
	it.todo(
		"accepts a submitSummary and broadcasts summaryAck with handle + sequence number",
	);
	it.todo("rejects an invalid summary submission with summaryNack");
	it.todo(
		"a client connecting after a summary receives summaryHandle/summarySequenceNumber in connect_document_success",
	);
});

describe.runIf(sluiceAvailable && isLeveeProxyTarget)(
	"Sluice contract — reconnect & audience/presence roster",
	{ timeout: 30_000 },
	() => {
		it("a second client's initialClients includes a still-connected first client (presence roster)", async () => {
			const documentId = uniqueDocId("sluice-audience");
			const factory = createSluiceServiceFactory();
			const resolvedUrl = createSluiceResolvedUrl(documentId);
			const service = await factory.createDocumentService(resolvedUrl);

			const first = await service.connectToDeltaStream(
				createSluiceTestClient("audience-client-1"),
			);
			try {
				const second = await service.connectToDeltaStream(
					createSluiceTestClient("audience-client-2"),
				);
				try {
					const rosterClientIds = second.initialClients.map(
						(entry) => entry.clientId,
					);
					expect(rosterClientIds).toContain(first.clientId);
				} finally {
					second.dispose();
				}
			} finally {
				first.dispose();
			}
		});

		it("a client that disconnects and reconnects establishes a new delta-stream connection to the same document", async () => {
			const documentId = uniqueDocId("sluice-reconnect");
			const factory = createSluiceServiceFactory();
			const resolvedUrl = createSluiceResolvedUrl(documentId);
			const service = await factory.createDocumentService(resolvedUrl);

			const initial = await service.connectToDeltaStream(testClient);
			const firstClientId = initial.clientId;
			initial.dispose();

			const reconnected = await service.connectToDeltaStream(testClient);
			try {
				expect(reconnected.clientId).toBeDefined();
				expect(reconnected.clientId).not.toBe(firstClientId);
				// The response always reports existing:true today (the join
				// handler in server/lib/levee/documents/session.ex hard-codes
				// it — see the "reports existing:false for a brand-new
				// document" todo above), but a reconnect to an already-created
				// session must at least be consistently "existing".
				expect(reconnected.existing).toBe(true);
			} finally {
				reconnected.dispose();
			}
		});

		it.todo(
			"a client that disconnects and reconnects can request missed ops via the driver's connectToDeltaStorage()/fetchMessages — " +
				"blocked today: the resolved URL's deltaStorageUrl is built as " +
				"`/documents/:tenant/:id/deltas` (matching the Storage Service HTTP " +
				"API shape the driver expects) but the only implemented REST route " +
				"is `GET /deltas/:tenant_id/:id` (server/lib/levee_web/router.ex); " +
				"the REST-level equivalent is covered directly in " +
				"'Sluice conformance — document REST lifecycle' below",
		);
		it.todo(
			"reconnecting with a stale client-sequence-number resumes without duplicate/missing ops",
		);
		it.todo(
			"[sluice-direct target] presence roster / reconnect — blocked on the " +
				"same delta-stream connect gap noted above under 'Sluice " +
				"Routerlicious compatibility contract' (standalone Sluice's " +
				"WebSocket transport doesn't speak Socket.IO yet).",
		);
	},
);

describe("Sluice contract — REST endpoints required by the driver", () => {
	it("defines the create-document, session-discovery, and deltas endpoints", () => {
		expect(SLUICE_REST_ENDPOINTS.createDocument("fluid")).toBe(
			"/documents/fluid",
		);
		expect(SLUICE_REST_ENDPOINTS.sessionDiscovery("fluid", "doc-1")).toBe(
			"/documents/fluid/session/doc-1",
		);
		expect(SLUICE_REST_ENDPOINTS.deltas("fluid", "doc-1")).toBe(
			"/deltas/fluid/doc-1",
		);
	});

	it("defines git blob/tree/commit/ref endpoints", () => {
		expect(SLUICE_REST_ENDPOINTS.gitBlob("fluid", "abc123")).toBe(
			"/repos/fluid/git/blobs/abc123",
		);
		expect(SLUICE_REST_ENDPOINTS.gitTree("fluid", "abc123")).toBe(
			"/repos/fluid/git/trees/abc123",
		);
		expect(SLUICE_REST_ENDPOINTS.gitCommit("fluid", "abc123")).toBe(
			"/repos/fluid/git/commits/abc123",
		);
		expect(SLUICE_REST_ENDPOINTS.gitRefs("fluid")).toBe(
			"/repos/fluid/git/refs",
		);
		expect(SLUICE_REST_ENDPOINTS.gitRef("fluid", "heads/main")).toBe(
			"/repos/fluid/git/refs/heads/main",
		);
	});

	it.todo("GET deltas paginates and returns ops in sequenceNumber order");
});

describe.runIf(sluiceAvailable)(
	"Sluice conformance — document REST lifecycle",
	() => {
		it.runIf(isLeveeProxyTarget)(
			"POST /documents/:tenant_id creates a document through the official REST path",
			async () => {
				const documentId = uniqueDocId("sluice-doc-create");

				const response = await sluiceFetch(
					SLUICE_REST_ENDPOINTS.createDocument(SLUICE_TENANT_ID),
					{ method: "POST", body: { id: documentId }, documentId },
				);

				expect(response.status).toBe(201);
			},
		);

		it.todo(
			"[sluice-direct target] POST /documents/:tenant_id (Routerlicious's " +
				"two-segment create-document shape, `SLUICE_REST_ENDPOINTS.createDocument`) " +
				"— standalone Sluice only accepts the three-segment " +
				"`POST /documents/:tenant/:doc` in `server/sluice/src/sluice.gleam`'s " +
				"`rest/2`, so this 404s today; confirmed by running this suite live " +
				"against `gleam run` on port 3000. Covered above for the " +
				"levee-proxy target (`document_controller.ex#create`).",
		);

		it.runIf(isLeveeProxyTarget)(
			"GET session discovery returns an ordering-service URL usable by the driver's session discovery",
			async () => {
				const documentId = uniqueDocId("sluice-doc-session");

				await sluiceFetch(
					SLUICE_REST_ENDPOINTS.createDocument(SLUICE_TENANT_ID),
					{
						method: "POST",
						body: { id: documentId },
						documentId,
					},
				);

				const response = await sluiceFetch(
					SLUICE_REST_ENDPOINTS.sessionDiscovery(SLUICE_TENANT_ID, documentId),
					{ documentId },
				);

				expect(response.status).toBe(200);
				const session = await response.json();
				expect(typeof session.ordererUrl).toBe("string");
				expect(typeof session.deltaStreamUrl).toBe("string");
			},
		);

		it.todo(
			"[sluice-direct target] GET session discovery — not yet implemented by " +
				"the standalone Sluice service; `server/sluice/src/sluice.gleam`'s " +
				"`rest/2` route match has no `session` branch, only " +
				"documents/deltas/git. Covered above for the levee-proxy target " +
				"(`server/lib/levee_web/controllers/document_controller.ex`'s " +
				"session-discovery action).",
		);

		it.runIf(isLeveeProxyTarget)(
			"GET deltas returns an empty ops array for a brand-new document",
			async () => {
				const documentId = uniqueDocId("sluice-doc-deltas");

				await sluiceFetch(
					SLUICE_REST_ENDPOINTS.createDocument(SLUICE_TENANT_ID),
					{
						method: "POST",
						body: { id: documentId },
						documentId,
					},
				);

				const response = await sluiceFetch(
					SLUICE_REST_ENDPOINTS.deltas(SLUICE_TENANT_ID, documentId),
					{ documentId },
				);

				expect(response.status).toBe(200);
				const body = await response.json();
				expect(Array.isArray(body.value)).toBe(true);
				expect(body.value).toHaveLength(0);
			},
		);

		it.todo(
			"[sluice-direct target] GET /deltas/:tenant/:doc (Routerlicious's " +
				"top-level deltas-catch-up shape) — standalone Sluice only exposes " +
				"catch-up nested under the document, `GET /documents/:tenant/:doc/deltas` " +
				"in `server/sluice/src/sluice.gleam`'s `rest/2`, and its response " +
				"shape is `{sequenceNumber, contents}` per op rather than the " +
				"Storage Service `{value: [...]}` envelope; confirmed by running " +
				"this suite live against `gleam run` on port 3000. Covered above " +
				"for the levee-proxy target (`delta_controller.ex#index`).",
		);
	},
);

describe.runIf(sluiceAvailable)(
	"Sluice conformance — git object storage (summary upload path)",
	() => {
		it.runIf(isLeveeProxyTarget)(
			"round-trips a blob through the git-like content-addressed storage endpoints",
			async () => {
				const content = Buffer.from(
					JSON.stringify({ hello: "sluice" }),
				).toString("base64");

				const createResponse = await sluiceFetch(
					SLUICE_REST_ENDPOINTS.gitCreateBlob(SLUICE_TENANT_ID),
					{
						method: "POST",
						body: { content, encoding: "base64" },
						scopes: ["doc:read", "summary:write"],
					},
				);
				expect(createResponse.status).toBe(201);
				const { sha } = await createResponse.json();
				expect(typeof sha).toBe("string");

				const readResponse = await sluiceFetch(
					SLUICE_REST_ENDPOINTS.gitBlob(SLUICE_TENANT_ID, sha),
				);
				expect(readResponse.status).toBe(200);
				const blob = await readResponse.json();
				expect(blob.sha).toBe(sha);
				expect(blob.encoding).toBe("base64");
				expect(Buffer.from(blob.content, "base64").toString()).toBe(
					JSON.stringify({ hello: "sluice" }),
				);
			},
		);

		it.todo(
			"[sluice-direct target] GET blob response envelope — standalone " +
				"Sluice's git store (`sluice/git.gleam`'s `fetch/2`) returns the " +
				"raw stored body directly, not the Levee/Historian-style " +
				"`{sha, encoding, content}` JSON envelope " +
				"(`git_controller.ex`'s blob-show action) the driver's storage " +
				"layer expects; confirmed by running this suite live against " +
				"`gleam run` on port 3000 (`blob.sha` came back `undefined`). " +
				"Covered above for the levee-proxy target.",
		);

		it("creates a tree over a blob, then a commit over the tree", async () => {
			const commitSha = await createBlobTreeCommit(
				SLUICE_TENANT_ID,
				"sluice conformance content",
				"Sluice conformance commit",
			);

			expect(typeof commitSha).toBe("string");
		});

		it.runIf(isLeveeProxyTarget)(
			"creates a ref pointing at a commit and reads it back",
			async () => {
				const commitSha = await createBlobTreeCommit(
					SLUICE_TENANT_ID,
					"sluice conformance ref content",
					"Sluice conformance ref commit",
				);

				const refName = `refs/heads/${uniqueDocId("sluice-conformance")}`;
				const refResponse = await sluiceFetch(
					SLUICE_REST_ENDPOINTS.gitRefs(SLUICE_TENANT_ID),
					{
						method: "POST",
						body: { ref: refName, sha: commitSha },
						scopes: ["doc:read", "summary:write"],
					},
				);
				expect(refResponse.status).toBe(201);

				const shortRef = refName.replace(/^refs\//, "");
				const readRefResponse = await sluiceFetch(
					SLUICE_REST_ENDPOINTS.gitRef(SLUICE_TENANT_ID, shortRef),
				);
				expect(readRefResponse.status).toBe(200);
				const ref = await readRefResponse.json();
				expect(ref.object.sha).toBe(commitSha);
			},
		);

		it.todo(
			"[sluice-direct target] git ref create/read — not yet implemented by " +
				"the standalone Sluice service; `server/sluice/src/sluice.gleam`'s " +
				"`rest/2` route match only handles git `blobs`/`trees`/`commits`, " +
				"no `refs` branch. Covered above for the levee-proxy target " +
				"(`server/lib/levee_web/controllers/git_controller.ex`'s ref actions).",
		);
	},
);

describe("Sluice contract — auth/token expectations", () => {
	it("requires doc:read+doc:write scopes to create a document, per router.ex write_access", () => {
		expect(SLUICE_REQUIRED_SCOPES.createDocument).toEqual([
			SLUICE_AUTH_SCOPES.docRead,
			SLUICE_AUTH_SCOPES.docWrite,
		]);
	});

	it("requires doc:read+summary:write scopes for git write endpoints, per router.ex summary_access", () => {
		expect(SLUICE_REQUIRED_SCOPES.gitWrite).toEqual([
			SLUICE_AUTH_SCOPES.docRead,
			SLUICE_AUTH_SCOPES.summaryWrite,
		]);
	});

	it.todo(
		"rejects connect_document/REST requests with a token signed by the wrong tenant's key",
	);
	it.todo(
		"rejects requests using a token missing a required scope with a 401/403-equivalent",
	);
	it.todo(
		"validates tokens minted via the tenant token-mint integration (server/lib/levee_web/controllers/token_mint_controller.ex analogue)",
	);
});

describe.todo("Sluice contract — storage backend interface", () => {
	it.todo(
		"the ETS-backed storage implementation satisfies the same behaviour used by the future PostgreSQL backend",
	);
	it.todo(
		"switching storage backends does not change any wire-visible REST/socket contract above",
	);
});
