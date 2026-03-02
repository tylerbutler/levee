/**
 * Integration tests for Levee server REST API endpoints.
 *
 * Tests the HTTP API contract directly (no Fluid Framework driver layer).
 * Requires a running Levee server — skipped automatically if unavailable.
 */

import { SignJWT } from "jose";
import { v4 as uuid } from "uuid";
import { describe, expect, it } from "vitest";
import {
	authenticatedFetch,
	isServerRunning,
	LEVEE_HTTP_URL,
	LEVEE_TENANT_ID,
	LEVEE_TENANT_KEY,
	TEST_USER,
	uniqueDocId,
} from "./helpers.js";

const serverAvailable = await isServerRunning();

// --- Health ---

describe.runIf(serverAvailable)("REST API - Health", () => {
	it("GET /health returns 200 with status ok", async () => {
		const response = await fetch(`${LEVEE_HTTP_URL}/health`);
		expect(response.ok).toBe(true);

		const body = await response.json();
		expect(body).toEqual({ status: "ok" });
	});
});

// --- Documents ---

describe.runIf(serverAvailable)("REST API - Documents", () => {
	it("POST /documents/:tenant_id creates a document", async () => {
		const docId = uniqueDocId("doc-create");
		const response = await authenticatedFetch(`/documents/${LEVEE_TENANT_ID}`, {
			method: "POST",
			body: { id: docId },
			documentId: docId,
		});

		expect(response.status).toBe(201);
	});

	it("POST /documents/:tenant_id with auto-generated ID", async () => {
		const response = await authenticatedFetch(`/documents/${LEVEE_TENANT_ID}`, {
			method: "POST",
			body: {},
		});

		expect(response.status).toBe(201);
	});

	it("POST /documents/:tenant_id returns 409 for duplicate ID", async () => {
		const docId = uniqueDocId("doc-dup");

		// Create first
		const first = await authenticatedFetch(`/documents/${LEVEE_TENANT_ID}`, {
			method: "POST",
			body: { id: docId },
			documentId: docId,
		});
		expect(first.status).toBe(201);

		// Create duplicate
		const second = await authenticatedFetch(`/documents/${LEVEE_TENANT_ID}`, {
			method: "POST",
			body: { id: docId },
			documentId: docId,
		});
		expect(second.status).toBe(409);
	});

	it("GET /documents/:tenant_id/:id returns document metadata", async () => {
		const docId = uniqueDocId("doc-get");

		// Create first
		await authenticatedFetch(`/documents/${LEVEE_TENANT_ID}`, {
			method: "POST",
			body: { id: docId },
			documentId: docId,
		});

		// Fetch
		const response = await authenticatedFetch(
			`/documents/${LEVEE_TENANT_ID}/${docId}`,
			{ documentId: docId },
		);

		expect(response.status).toBe(200);
		const body = await response.json();
		expect(body.id).toBe(docId);
		expect(body.tenantId).toBe(LEVEE_TENANT_ID);
		expect(typeof body.sequenceNumber).toBe("number");
	});

	it("GET /documents/:tenant_id/:id returns 404 for nonexistent document", async () => {
		const docId = uniqueDocId("doc-missing");
		const response = await authenticatedFetch(
			`/documents/${LEVEE_TENANT_ID}/${docId}`,
			{ documentId: docId },
		);

		expect(response.status).toBe(404);
	});
});

// --- Deltas ---

describe.runIf(serverAvailable)("REST API - Deltas", () => {
	it("GET /deltas/:tenant_id/:id returns empty array for new document", async () => {
		const docId = uniqueDocId("delta-empty");

		// Create the document first
		await authenticatedFetch(`/documents/${LEVEE_TENANT_ID}`, {
			method: "POST",
			body: { id: docId },
			documentId: docId,
		});

		const response = await authenticatedFetch(
			`/deltas/${LEVEE_TENANT_ID}/${docId}`,
			{ documentId: docId },
		);

		expect(response.status).toBe(200);
		const body = await response.json();
		expect(Array.isArray(body)).toBe(true);
	});

	it("GET /deltas/:tenant_id/:id supports from/to query parameters", async () => {
		const docId = uniqueDocId("delta-params");

		await authenticatedFetch(`/documents/${LEVEE_TENANT_ID}`, {
			method: "POST",
			body: { id: docId },
			documentId: docId,
		});

		const response = await authenticatedFetch(
			`/deltas/${LEVEE_TENANT_ID}/${docId}?from=0&to=100`,
			{ documentId: docId },
		);

		expect(response.status).toBe(200);
		const body = await response.json();
		expect(Array.isArray(body)).toBe(true);
	});
});

// --- Git Storage: Blobs ---

describe.runIf(serverAvailable)("REST API - Git Blobs", () => {
	it("POST /repos/:tenant_id/git/blobs creates a blob", async () => {
		const content = btoa("Hello, Levee!");
		const response = await authenticatedFetch(
			`/repos/${LEVEE_TENANT_ID}/git/blobs`,
			{
				method: "POST",
				body: { content, encoding: "base64" },
				scopes: ["doc:read", "summary:write"],
			},
		);

		expect(response.status).toBe(201);
		const body = await response.json();
		expect(body.sha).toBeDefined();
		expect(typeof body.sha).toBe("string");
		expect(body.url).toContain("/git/blobs/");
	});

	it("GET /repos/:tenant_id/git/blobs/:sha retrieves a blob", async () => {
		const originalContent = "Blob round-trip test";
		const encoded = btoa(originalContent);

		// Create
		const createResponse = await authenticatedFetch(
			`/repos/${LEVEE_TENANT_ID}/git/blobs`,
			{
				method: "POST",
				body: { content: encoded, encoding: "base64" },
				scopes: ["doc:read", "summary:write"],
			},
		);
		const { sha } = (await createResponse.json()) as { sha: string };

		// Retrieve
		const getResponse = await authenticatedFetch(
			`/repos/${LEVEE_TENANT_ID}/git/blobs/${sha}`,
			{ scopes: ["doc:read"] },
		);

		expect(getResponse.status).toBe(200);
		const body = await getResponse.json();
		expect(body.sha).toBe(sha);
		expect(body.encoding).toBe("base64");

		// Verify round-trip
		const decoded = atob(body.content);
		expect(decoded).toBe(originalContent);
	});

	it("GET /repos/:tenant_id/git/blobs/:sha returns 404 for nonexistent", async () => {
		const fakeSha = "0000000000000000000000000000000000000000";
		const response = await authenticatedFetch(
			`/repos/${LEVEE_TENANT_ID}/git/blobs/${fakeSha}`,
			{ scopes: ["doc:read"] },
		);

		expect(response.status).toBe(404);
	});
});

// --- Git Storage: Trees ---

describe.runIf(serverAvailable)("REST API - Git Trees", () => {
	it("creates and retrieves a tree", async () => {
		// First create a blob to reference in the tree
		const blobResponse = await authenticatedFetch(
			`/repos/${LEVEE_TENANT_ID}/git/blobs`,
			{
				method: "POST",
				body: { content: btoa("tree test content"), encoding: "base64" },
				scopes: ["doc:read", "summary:write"],
			},
		);
		const { sha: blobSha } = (await blobResponse.json()) as { sha: string };

		// Create tree
		const createResponse = await authenticatedFetch(
			`/repos/${LEVEE_TENANT_ID}/git/trees`,
			{
				method: "POST",
				body: {
					tree: [
						{
							path: "test-file.txt",
							mode: "100644",
							sha: blobSha,
							type: "blob",
						},
					],
				},
				scopes: ["doc:read", "summary:write"],
			},
		);

		expect(createResponse.status).toBe(201);
		const tree = await createResponse.json();
		expect(tree.sha).toBeDefined();
		expect(tree.tree).toHaveLength(1);
		expect(tree.tree[0].path).toBe("test-file.txt");

		// Retrieve tree
		const getResponse = await authenticatedFetch(
			`/repos/${LEVEE_TENANT_ID}/git/trees/${tree.sha}`,
			{ scopes: ["doc:read"] },
		);

		expect(getResponse.status).toBe(200);
		const retrieved = await getResponse.json();
		expect(retrieved.sha).toBe(tree.sha);
		expect(retrieved.tree).toHaveLength(1);
	});

	it("GET /repos/:tenant_id/git/trees/:sha returns 404 for nonexistent", async () => {
		const fakeSha = "0000000000000000000000000000000000000000";
		const response = await authenticatedFetch(
			`/repos/${LEVEE_TENANT_ID}/git/trees/${fakeSha}`,
			{ scopes: ["doc:read"] },
		);

		expect(response.status).toBe(404);
	});
});

// --- Git Storage: Commits ---

describe.runIf(serverAvailable)("REST API - Git Commits", () => {
	it("creates and retrieves a commit", async () => {
		// Create blob -> tree -> commit chain
		const blobResponse = await authenticatedFetch(
			`/repos/${LEVEE_TENANT_ID}/git/blobs`,
			{
				method: "POST",
				body: { content: btoa("commit test"), encoding: "base64" },
				scopes: ["doc:read", "summary:write"],
			},
		);
		const { sha: blobSha } = (await blobResponse.json()) as { sha: string };

		const treeResponse = await authenticatedFetch(
			`/repos/${LEVEE_TENANT_ID}/git/trees`,
			{
				method: "POST",
				body: {
					tree: [
						{ path: "data.txt", mode: "100644", sha: blobSha, type: "blob" },
					],
				},
				scopes: ["doc:read", "summary:write"],
			},
		);
		const { sha: treeSha } = (await treeResponse.json()) as { sha: string };

		// Create commit
		const now = Math.floor(Date.now() / 1000);
		const createResponse = await authenticatedFetch(
			`/repos/${LEVEE_TENANT_ID}/git/commits`,
			{
				method: "POST",
				body: {
					tree: treeSha,
					parents: [],
					message: "integration test commit",
					author: {
						name: "Test User",
						email: "test@example.com",
						date: now,
					},
				},
				scopes: ["doc:read", "summary:write"],
			},
		);

		expect(createResponse.status).toBe(201);
		const commit = await createResponse.json();
		expect(commit.sha).toBeDefined();
		expect(commit.message).toBe("integration test commit");

		// Retrieve commit
		const getResponse = await authenticatedFetch(
			`/repos/${LEVEE_TENANT_ID}/git/commits/${commit.sha}`,
			{ scopes: ["doc:read"] },
		);

		expect(getResponse.status).toBe(200);
		const retrieved = await getResponse.json();
		expect(retrieved.sha).toBe(commit.sha);
		expect(retrieved.tree.sha).toBe(treeSha);
	});
});

// --- Git Storage: Refs ---

describe.runIf(serverAvailable)("REST API - Git Refs", () => {
	it("full git workflow: blob -> tree -> commit -> ref", async () => {
		const refSuffix = uniqueDocId("ref");

		// Create blob
		const blobResponse = await authenticatedFetch(
			`/repos/${LEVEE_TENANT_ID}/git/blobs`,
			{
				method: "POST",
				body: { content: btoa("ref workflow test"), encoding: "base64" },
				scopes: ["doc:read", "summary:write"],
			},
		);
		const { sha: blobSha } = (await blobResponse.json()) as { sha: string };

		// Create tree
		const treeResponse = await authenticatedFetch(
			`/repos/${LEVEE_TENANT_ID}/git/trees`,
			{
				method: "POST",
				body: {
					tree: [
						{ path: "file.txt", mode: "100644", sha: blobSha, type: "blob" },
					],
				},
				scopes: ["doc:read", "summary:write"],
			},
		);
		const { sha: treeSha } = (await treeResponse.json()) as { sha: string };

		// Create commit
		const now = Math.floor(Date.now() / 1000);
		const commitResponse = await authenticatedFetch(
			`/repos/${LEVEE_TENANT_ID}/git/commits`,
			{
				method: "POST",
				body: {
					tree: treeSha,
					parents: [],
					message: "ref test commit",
					author: { name: "Test", email: "test@test.com", date: now },
				},
				scopes: ["doc:read", "summary:write"],
			},
		);
		const { sha: commitSha } = (await commitResponse.json()) as { sha: string };

		// Create ref
		const refPath = `refs/heads/${refSuffix}`;
		const createRefResponse = await authenticatedFetch(
			`/repos/${LEVEE_TENANT_ID}/git/refs`,
			{
				method: "POST",
				body: { ref: refPath, sha: commitSha },
				scopes: ["doc:read", "summary:write"],
			},
		);
		expect(createRefResponse.status).toBe(201);

		// Get ref
		const getRefResponse = await authenticatedFetch(
			`/repos/${LEVEE_TENANT_ID}/git/refs/heads/${refSuffix}`,
			{ scopes: ["doc:read"] },
		);
		expect(getRefResponse.status).toBe(200);
		const ref = await getRefResponse.json();
		expect(ref.object.sha).toBe(commitSha);

		// Create second commit for update
		const commit2Response = await authenticatedFetch(
			`/repos/${LEVEE_TENANT_ID}/git/commits`,
			{
				method: "POST",
				body: {
					tree: treeSha,
					parents: [commitSha],
					message: "updated ref commit",
					author: { name: "Test", email: "test@test.com", date: now + 1 },
				},
				scopes: ["doc:read", "summary:write"],
			},
		);
		const { sha: commit2Sha } = (await commit2Response.json()) as {
			sha: string;
		};

		// Update ref
		const updateRefResponse = await authenticatedFetch(
			`/repos/${LEVEE_TENANT_ID}/git/refs/heads/${refSuffix}`,
			{
				method: "PATCH",
				body: { sha: commit2Sha },
				scopes: ["doc:read", "summary:write"],
			},
		);
		expect(updateRefResponse.status).toBe(200);
		const updatedRef = await updateRefResponse.json();
		expect(updatedRef.object.sha).toBe(commit2Sha);
	});
});

// --- Authentication Errors ---

describe.runIf(serverAvailable)("REST API - Authentication", () => {
	it("rejects requests without Authorization header", async () => {
		const docId = uniqueDocId("auth-none");
		const response = await fetch(
			`${LEVEE_HTTP_URL}/documents/${LEVEE_TENANT_ID}/${docId}`,
		);

		expect(response.status).toBe(401);
		const body = await response.json();
		expect(body.error).toContain("Missing Authorization");
	});

	it("rejects requests with invalid JWT", async () => {
		const docId = uniqueDocId("auth-invalid");
		const response = await fetch(
			`${LEVEE_HTTP_URL}/documents/${LEVEE_TENANT_ID}/${docId}`,
			{
				headers: { Authorization: "Bearer not-a-valid-jwt" },
			},
		);

		expect(response.status).toBe(401);
	});

	it("rejects requests with expired JWT", async () => {
		const docId = uniqueDocId("auth-expired");
		const secret = new TextEncoder().encode(LEVEE_TENANT_KEY);
		const pastTime = Math.floor(Date.now() / 1000) - 7200; // 2 hours ago

		const expiredToken = await new SignJWT({
			documentId: docId,
			tenantId: LEVEE_TENANT_ID,
			scopes: ["doc:read"],
			user: TEST_USER,
			ver: "1.0",
			jti: uuid(),
		})
			.setProtectedHeader({ alg: "HS256" })
			.setIssuedAt(pastTime)
			.setExpirationTime(pastTime + 3600) // expired 1 hour ago
			.sign(secret);

		const response = await fetch(
			`${LEVEE_HTTP_URL}/documents/${LEVEE_TENANT_ID}/${docId}`,
			{
				headers: { Authorization: `Bearer ${expiredToken}` },
			},
		);

		expect(response.status).toBe(401);
		const body = await response.json();
		expect(body.error).toContain("expired");
	});

	it("rejects requests with insufficient scopes", async () => {
		const docId = uniqueDocId("auth-scope");

		// Create document first (needs write scope)
		await authenticatedFetch(`/documents/${LEVEE_TENANT_ID}`, {
			method: "POST",
			body: { id: docId },
			documentId: docId,
		});

		// Try to write a blob with read-only token
		const response = await authenticatedFetch(
			`/repos/${LEVEE_TENANT_ID}/git/blobs`,
			{
				method: "POST",
				body: { content: btoa("should fail"), encoding: "base64" },
				scopes: ["doc:read"], // missing summary:write
			},
		);

		expect(response.status).toBe(403);
		const body = await response.json();
		expect(body.error).toContain("scope");
	});
});
