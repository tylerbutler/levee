import { describe, expect, it } from "vitest";

import {
	buildAppUrl,
	buildIframeSrc,
	type SandbagRecord,
} from "../../src/lib/api.js";

const RECORD: SandbagRecord = {
	id: "test-id",
	name: "Test Sandbag",
	appType: "dice-roller",
	documentId: "doc-1",
	createdAt: "2024-01-01T00:00:00.000Z",
};

describe("buildAppUrl", () => {
	it("builds a bare app path", () => {
		expect(buildAppUrl("dice-roller")).toBe("/apps/dice-roller");
	});

	it("includes document and auth parameters", () => {
		const url = buildAppUrl("dice-roller", "doc-1", "token");
		const parsed = new URL(url, "http://localhost");
		expect(parsed.searchParams.get("documentId")).toBe("doc-1");
		expect(parsed.searchParams.get("authToken")).toBe("token");
	});
});

describe("buildIframeSrc", () => {
	it("uses the record document and current auth token", () => {
		const url = buildIframeSrc(RECORD, "token");
		const parsed = new URL(url, "http://localhost");
		expect(parsed.searchParams.get("documentId")).toBe("doc-1");
		expect(parsed.searchParams.get("authToken")).toBe("token");
	});
});
