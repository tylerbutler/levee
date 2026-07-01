/**
 * Shared live-target configuration for the Sluice/Routerlicious conformance
 * suite (`sluice-routerlicious.test.ts`).
 *
 * The same test file is meant to run, unmodified, against two different
 * backends by pointing these env vars at whichever one is up:
 *
 *   | Target                          | SLUICE_HTTP_URL / SLUICE_SOCKET_URL       |
 *   |---------------------------------|--------------------------------------------|
 *   | Sluice (Gleam service) direct   | `http://localhost:3000` (default; `server/sluice/src/sluice.gleam`'s `main()`/`serve/1` starts a Mist listener on port 3000) |
 *   | Levee proxying/mounting Sluice  | `http://localhost:4000` (Phoenix)           |
 *
 * The standalone `sluice/` service *does* expose its own HTTP/WS listener
 * today (Mist, started by `serve/1`/`main()` in `sluice.gleam`) — it is not
 * gated behind Levee. Its REST surface is currently a minimal subset,
 * though: only document create, deltas catch-up, and git blob/tree/commit
 * object storage are implemented; session-discovery
 * (`GET /documents/:tenant/session/:doc`) and git ref endpoints
 * (`POST/GET /repos/:tenant/git/refs...`) exist only on Levee's proxy today.
 * Run the same test file against both targets by pointing these env vars
 * at whichever backend is up; tests that need routes standalone Sluice
 * doesn't have yet are gated on `SLUICE_TARGET_LABEL` with a matching
 * `it.todo` explaining the gap (see `sluice-routerlicious.test.ts`).
 *
 * Neither target is assumed to be running by default — `isSluiceRunning()`
 * probes the configured URL and callers gate live tests on the result via
 * `describe.runIf`/`it.runIf`. Set `SLUICE_ROUTERLICIOUS_COMPAT=1` to opt in
 * to the probe at all (matches the existing `test:sluice-routerlicious`
 * script); otherwise live tests are skipped without making a network call.
 *
 * To run against both targets:
 *   1. Levee proxy:    start Levee (`just server`, port 4000, the default
 *      env), then `SLUICE_ROUTERLICIOUS_COMPAT=1 pnpm test:sluice-routerlicious`.
 *   2. Sluice direct:  start the standalone service (`cd server/sluice &&
 *      gleam run`, port 3000), then run with
 *      `SLUICE_ROUTERLICIOUS_COMPAT=1 SLUICE_HTTP_URL=http://localhost:3000
 *      SLUICE_SOCKET_URL=http://localhost:3000 pnpm test:sluice-routerlicious`
 *      (these are also the defaults, so plain `SLUICE_ROUTERLICIOUS_COMPAT=1
 *      pnpm test:sluice-routerlicious` targets Sluice directly out of the box).
 */

import type { IResolvedUrl } from "@fluidframework/driver-definitions/internal";
import { SummaryType } from "@fluidframework/driver-definitions/internal";
import type {
	IClient,
	ISummaryTree,
} from "@fluidframework/protocol-definitions";
import { RouterliciousDocumentServiceFactory } from "@fluidframework/routerlicious-driver/internal";
import { SignJWT } from "jose";
import { v4 as uuid } from "uuid";
import { InsecureLeveeTokenProvider } from "../../src/tokenProvider.js";

export const SLUICE_HTTP_URL = (
	process.env["SLUICE_HTTP_URL"] ?? "http://localhost:3000"
).replace(/\/$/, "");
export const SLUICE_SOCKET_URL =
	process.env["SLUICE_SOCKET_URL"] ?? SLUICE_HTTP_URL;
export const SLUICE_TENANT_ID = process.env["SLUICE_TENANT_ID"] ?? "fluid";
/**
 * Standalone Sluice's `authorize()` (see `sluice/document_channel.gleam`)
 * skips JWT verification entirely when its own `SLUICE_JWT_SECRET` is unset,
 * so any non-empty client-side secret works against it. It must still be
 * non-empty here regardless, though: `jose`'s HMAC signer throws
 * ("Zero-length key is not supported") on an empty key when *minting* the
 * token client-side, independent of whether the receiving end checks it.
 * When pointed at Levee's proxy, override this to match its configured
 * tenant secret (e.g. `dev-tenant-secret-key` in
 * `client/packages/levee-driver/docker-compose.yml`).
 */
export const SLUICE_JWT_SECRET =
	process.env["SLUICE_JWT_SECRET"] ?? "sluice-routerlicious-compat-secret";

/**
 * Opt-in switch: live probing/tests only run when this is set, regardless of
 * whether a server happens to be reachable at `SLUICE_HTTP_URL`. This keeps
 * default `vitest run` (no env vars) from ever attempting network calls.
 */
export const RUN_ROUTERLICIOUS_COMPAT =
	process.env["SLUICE_ROUTERLICIOUS_COMPAT"] === "1" ||
	process.env["SLUICE_ROUTERLICIOUS_COMPAT"] === "true";

/** Human-readable label for which target this run is exercising, for logs. */
export const SLUICE_TARGET_LABEL =
	process.env["SLUICE_TARGET_LABEL"] ??
	(SLUICE_HTTP_URL.includes(":4000") ? "levee-proxy" : "sluice-direct");

/**
 * True when this run is pointed at Levee's proxy/mount of Sluice rather than
 * the standalone Gleam service. Some REST routes (session discovery, git
 * refs) are implemented only on the Levee-proxy side today — see the
 * target-matrix comment above — so tests exercising those routes gate on
 * this instead of assuming every route exists on every target.
 */
export const isLeveeProxyTarget = SLUICE_TARGET_LABEL === "levee-proxy";

export function createSluiceResolvedUrl(documentId: string): IResolvedUrl {
	return {
		type: "fluid",
		id: documentId,
		url: `${SLUICE_HTTP_URL}/${SLUICE_TENANT_ID}/${documentId}`,
		tokens: {},
		endpoints: {
			ordererUrl: SLUICE_HTTP_URL,
			deltaStorageUrl: `${SLUICE_HTTP_URL}/documents/${SLUICE_TENANT_ID}/${documentId}/deltas`,
			deltaStreamUrl: SLUICE_SOCKET_URL,
			storageUrl: `${SLUICE_HTTP_URL}/repos/${SLUICE_TENANT_ID}`,
		},
	};
}

/**
 * Minimal `.app` + `.protocol` combined summary tree satisfying
 * `isCombinedAppAndProtocolSummary`/`getDocAttributesFromProtocolSummary`/
 * `getQuorumValuesFromProtocolSummary` (from `@fluidframework/driver-utils`,
 * used internally by `RouterliciousDocumentServiceFactory.createContainer`).
 * Used by the official create-container conformance test — this is the
 * smallest summary shape the real driver's create path will accept.
 */
export function createMinimalCombinedSummary(): ISummaryTree {
	return {
		type: SummaryType.Tree,
		tree: {
			".app": { type: SummaryType.Tree, tree: {} },
			".protocol": {
				type: SummaryType.Tree,
				tree: {
					attributes: {
						type: SummaryType.Blob,
						content: JSON.stringify({
							minimumSequenceNumber: 0,
							sequenceNumber: 0,
						}),
					},
					quorumValues: {
						type: SummaryType.Blob,
						content: JSON.stringify([]),
					},
				},
			},
		},
	};
}

/**
 * Result is intentionally not cached across calls: unlike the Levee-only
 * `helpers.ts#isServerRunning`, this suite may be re-pointed at a different
 * target between describe blocks in the future, so each caller decides when
 * to probe.
 */
export async function isSluiceRunning(): Promise<boolean> {
	if (!RUN_ROUTERLICIOUS_COMPAT) {
		return false;
	}
	try {
		const controller = new AbortController();
		const timeout = setTimeout(() => controller.abort(), 2000);
		const response = await fetch(SLUICE_HTTP_URL, {
			method: "GET",
			signal: controller.signal,
		});
		clearTimeout(timeout);

		return response.status < 500;
	} catch {
		return false;
	}
}

export function createSluiceTestClient(userId: string): IClient {
	return {
		mode: "write",
		details: {
			capabilities: { interactive: true },
			environment: "node:vitest",
		},
		permission: [],
		user: { id: userId },
		scopes: ["doc:read", "doc:write", "summary:write"],
	};
}

export function createSluiceTokenProvider(
	userId = "routerlicious-compat-user",
): InsecureLeveeTokenProvider {
	return new InsecureLeveeTokenProvider(
		SLUICE_JWT_SECRET,
		{ id: userId, name: "Routerlicious Compat User" },
		SLUICE_TENANT_ID,
	);
}

export function createSluiceServiceFactory(
	userId?: string,
): RouterliciousDocumentServiceFactory {
	return new RouterliciousDocumentServiceFactory(
		createSluiceTokenProvider(userId),
		{
			enableDiscovery: false,
			enableLongPollingDowngrade: false,
			// RestLess mode (on by default) moves the Authorization header into
			// an encoded request body for environments without XHR header
			// support; neither Sluice nor Levee's proxy understand that
			// encoding, so REST calls (e.g. createContainer()'s orderer POST)
			// would otherwise 401 with "Missing Authorization header" even
			// though a token was generated.
			enableRestLess: false,
		},
	);
}

/**
 * Mint a JWT for direct REST calls against the configured target (bypassing
 * the driver's own token provider), mirroring `helpers.ts#generateTestToken`
 * but parameterized over the Sluice target instead of the Levee-only one.
 */
export async function generateSluiceToken(
	documentId = "",
	scopes: string[] = ["doc:read", "doc:write", "summary:write"],
): Promise<string> {
	const now = Math.floor(Date.now() / 1000);
	const secret = new TextEncoder().encode(SLUICE_JWT_SECRET);

	return new SignJWT({
		documentId,
		tenantId: SLUICE_TENANT_ID,
		scopes,
		user: {
			id: "routerlicious-compat-user",
			name: "Routerlicious Compat User",
		},
		ver: "1.0",
		jti: uuid(),
	})
		.setProtectedHeader({ alg: "HS256" })
		.setIssuedAt(now)
		.setExpirationTime(now + 3600)
		.sign(secret);
}

/** Authenticated fetch against the configured Sluice/Levee target. */
export async function sluiceFetch(
	path: string,
	options: {
		method?: string;
		body?: unknown;
		documentId?: string;
		scopes?: string[];
	} = {},
): Promise<Response> {
	const token = await generateSluiceToken(
		options.documentId ?? "",
		options.scopes,
	);

	const headers: Record<string, string> = {
		Authorization: `Bearer ${token}`,
	};

	let body: string | undefined;
	if (options.body !== undefined) {
		headers["Content-Type"] = "application/json";
		body = JSON.stringify(options.body);
	}

	return fetch(`${SLUICE_HTTP_URL}${path}`, {
		method: options.method ?? "GET",
		headers,
		body,
	});
}

/**
 * Helper to create a blob, tree, and commit in sequence for git-storage
 * conformance tests. Returns the commit SHA.
 *
 * Each REST call status is asserted so test failures pinpoint which call failed.
 */
export async function createBlobTreeCommit(
	tenantId: string,
	contentStr: string,
	messageStr: string,
): Promise<string> {
	// Create blob from content string
	const content = Buffer.from(contentStr).toString("base64");
	const blobResponse = await sluiceFetch(`/repos/${tenantId}/git/blobs`, {
		method: "POST",
		body: { content, encoding: "base64" },
		scopes: ["doc:read", "summary:write"],
	});
	if (blobResponse.status !== 201) {
		throw new Error(
			`Expected blob creation to return 201, got ${blobResponse.status}`,
		);
	}
	const { sha: blobSha } = (await blobResponse.json()) as { sha: string };

	// Create tree from blob
	const treeResponse = await sluiceFetch(`/repos/${tenantId}/git/trees`, {
		method: "POST",
		body: {
			tree: [{ path: "file.txt", sha: blobSha, mode: "100644", type: "blob" }],
		},
		scopes: ["doc:read", "summary:write"],
	});
	if (treeResponse.status !== 201) {
		throw new Error(
			`Expected tree creation to return 201, got ${treeResponse.status}`,
		);
	}
	const { sha: treeSha } = (await treeResponse.json()) as { sha: string };

	// Create commit from tree
	const commitResponse = await sluiceFetch(`/repos/${tenantId}/git/commits`, {
		method: "POST",
		body: {
			tree: treeSha,
			parents: [],
			message: messageStr,
			author: {
				name: "Sluice Conformance Suite",
				email: "conformance@sluice.local",
				date: new Date().toISOString(),
			},
		},
		scopes: ["doc:read", "summary:write"],
	});
	if (commitResponse.status !== 201) {
		throw new Error(
			`Expected commit creation to return 201, got ${commitResponse.status}`,
		);
	}
	const { sha: commitSha } = (await commitResponse.json()) as { sha: string };

	return commitSha;
}
