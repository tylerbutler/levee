/**
 * Unit tests for Sandbag URL building helpers.
 *
 * Tests buildAppUrl with the new mintCredential parameter, ensuring it
 * is included in the query string without conflating it with authToken.
 *
 * Tests buildIframeSrc — the helper used by the sandbag/[id] caller —
 * verifying that mintCredential flows from the page URL param or the
 * per-record stored credential, never from authToken.
 *
 * Note: $app/paths is mocked via vitest.config.ts alias — base = "".
 */

import { describe, expect, it } from "vitest";

import {
	buildAppUrl,
	buildIframeSrc,
	type SandbagRecord,
} from "../../src/lib/api.js";

describe("buildAppUrl — bare paths", () => {
	it("returns /apps/{type} with no optional params", () => {
		expect(buildAppUrl("dice-roller")).toBe("/apps/dice-roller");
	});

	it("returns /apps/{type} for floodgate-dice-roller", () => {
		expect(buildAppUrl("floodgate-dice-roller")).toBe(
			"/apps/floodgate-dice-roller",
		);
	});
});

describe("buildAppUrl — query params", () => {
	it("includes documentId in query", () => {
		expect(buildAppUrl("dice-roller", "doc-123")).toBe(
			"/apps/dice-roller?documentId=doc-123",
		);
	});

	it("includes authToken in query", () => {
		expect(buildAppUrl("dice-roller", undefined, "tok-abc")).toBe(
			"/apps/dice-roller?authToken=tok-abc",
		);
	});

	it("includes mintCredential in query", () => {
		expect(
			buildAppUrl("floodgate-dice-roller", undefined, undefined, "mint-secret"),
		).toBe("/apps/floodgate-dice-roller?mintCredential=mint-secret");
	});

	it("includes documentId and mintCredential together", () => {
		const url = buildAppUrl(
			"floodgate-dice-roller",
			"doc-1",
			undefined,
			"mint-secret",
		);
		const parsed = new URL(url, "http://localhost");
		expect(parsed.searchParams.get("documentId")).toBe("doc-1");
		expect(parsed.searchParams.get("mintCredential")).toBe("mint-secret");
		expect(parsed.searchParams.has("authToken")).toBe(false);
	});

	it("includes authToken and documentId together", () => {
		const url = buildAppUrl("dice-roller", "doc-1", "tok-abc");
		const parsed = new URL(url, "http://localhost");
		expect(parsed.searchParams.get("documentId")).toBe("doc-1");
		expect(parsed.searchParams.get("authToken")).toBe("tok-abc");
		expect(parsed.searchParams.has("mintCredential")).toBe(false);
	});

	it("omits authToken when undefined (not Floodgate credential)", () => {
		const url = buildAppUrl(
			"floodgate-dice-roller",
			undefined,
			undefined,
			"mint-secret",
		);
		expect(url).not.toContain("authToken");
	});

	it("omits mintCredential when undefined (not Levee app)", () => {
		const url = buildAppUrl("dice-roller", undefined, "tok-abc");
		expect(url).not.toContain("mintCredential");
	});
});

// ---------------------------------------------------------------------------
// buildIframeSrc — the helper used by the sandbag/[id] caller
// ---------------------------------------------------------------------------

const BASE_RECORD: SandbagRecord = {
	id: "test-id",
	name: "Test Sandbag",
	appType: "floodgate-dice-roller",
	documentId: "doc-1",
	createdAt: "2024-01-01T00:00:00.000Z",
};

describe("buildIframeSrc — mintCredential propagation", () => {
	it("forwards page URL mintCredential into the iframe URL", () => {
		const url = buildIframeSrc(BASE_RECORD, undefined, "page-mint-cred");
		expect(url).toContain("mintCredential=page-mint-cred");
	});

	it("uses sandbag.mintCredential when no page credential is provided", () => {
		const record = { ...BASE_RECORD, mintCredential: "stored-cred" };
		const url = buildIframeSrc(record, undefined, undefined);
		expect(url).toContain("mintCredential=stored-cred");
	});

	it("page credential takes precedence over sandbag.mintCredential", () => {
		const record = { ...BASE_RECORD, mintCredential: "stored-cred" };
		const url = buildIframeSrc(record, undefined, "page-override");
		expect(url).toContain("mintCredential=page-override");
		expect(url).not.toContain("stored-cred");
	});

	it("omits mintCredential when absent from both page URL and record", () => {
		const url = buildIframeSrc(BASE_RECORD, undefined, undefined);
		expect(url).not.toContain("mintCredential");
	});

	it("passes authToken and mintCredential independently", () => {
		const url = buildIframeSrc(BASE_RECORD, "auth-tok", "mint-cred");
		const parsed = new URL(url, "http://localhost");
		expect(parsed.searchParams.get("authToken")).toBe("auth-tok");
		expect(parsed.searchParams.get("mintCredential")).toBe("mint-cred");
	});

	it("Levee app: passes authToken without mintCredential", () => {
		const leveeRecord: SandbagRecord = {
			...BASE_RECORD,
			appType: "dice-roller",
			mintCredential: undefined,
		};
		const url = buildIframeSrc(leveeRecord, "levee-auth-token", undefined);
		const parsed = new URL(url, "http://localhost");
		expect(parsed.searchParams.get("authToken")).toBe("levee-auth-token");
		expect(parsed.searchParams.has("mintCredential")).toBe(false);
	});

	it("Floodgate app: passes mintCredential without authToken", () => {
		const url = buildIframeSrc(BASE_RECORD, undefined, "floodgate-cred");
		const parsed = new URL(url, "http://localhost");
		expect(parsed.searchParams.has("authToken")).toBe(false);
		expect(parsed.searchParams.get("mintCredential")).toBe("floodgate-cred");
	});

	it("includes documentId from the sandbag record", () => {
		const url = buildIframeSrc(BASE_RECORD, undefined, "cred");
		const parsed = new URL(url, "http://localhost");
		expect(parsed.searchParams.get("documentId")).toBe("doc-1");
	});

	it("omits documentId when the record has an empty documentId", () => {
		const record = { ...BASE_RECORD, documentId: "" };
		const url = buildIframeSrc(record, undefined, undefined);
		const parsed = new URL(url, "http://localhost");
		expect(parsed.searchParams.has("documentId")).toBe(false);
	});
});
