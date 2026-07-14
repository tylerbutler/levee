/**
 * Unit tests for Sandbag app registry and URL helpers — floodgate-todo-list.
 *
 * Verifies:
 *   - APP_TYPES includes "floodgate-todo-list"
 *   - buildAppUrl returns the correct path for the new app type
 *
 * mintCredential propagation is already covered by api.test.ts (shared
 * mechanism reused without duplication).
 */

import { describe, expect, it } from "vitest";

import { buildAppUrl } from "../../src/lib/api.js";
import { APP_TYPES, loadApp } from "../../src/lib/registry.js";

describe("APP_TYPES registry", () => {
	it('includes "floodgate-todo-list"', () => {
		expect(APP_TYPES).toContain("floodgate-todo-list");
	});

	it('includes "floodgate-dice-roller"', () => {
		expect(APP_TYPES).toContain("floodgate-dice-roller");
	});

	it('includes "floodgate-presence"', () => {
		expect(APP_TYPES).toContain("floodgate-presence");
	});

	it('includes "todo-list" (Levee, unchanged)', () => {
		expect(APP_TYPES).toContain("todo-list");
	});
});

describe("loadApp — floodgate-todo-list", () => {
	it("resolves to the Floodgate Todo app descriptor", async () => {
		const app = await loadApp("floodgate-todo-list");
		expect(app, "loadApp should resolve a descriptor").toBeDefined();
		// Guard: must not accidentally load DiceRoller or Levee Todo
		expect(app?.id).toBe("floodgate-todo-list");
		expect(app?.label).toBe("Floodgate Todo List");
		expect(typeof app?.mount).toBe("function");
	});

	it("returns undefined for an unknown app type", async () => {
		const app = await loadApp("nonexistent-app");
		expect(app).toBeUndefined();
	});
});

describe("loadApp — floodgate-presence", () => {
	it("resolves to the Floodgate Presence descriptor", async () => {
		const app = await loadApp("floodgate-presence");
		expect(app).toMatchObject({
			id: "floodgate-presence",
			label: "Floodgate Presence",
		});
		expect(typeof app?.mount).toBe("function");
	});
});

describe("buildAppUrl — floodgate-todo-list", () => {
	it("returns /apps/floodgate-todo-list with no optional params", () => {
		expect(buildAppUrl("floodgate-todo-list")).toBe(
			"/apps/floodgate-todo-list",
		);
	});

	it("includes documentId in query", () => {
		expect(buildAppUrl("floodgate-todo-list", "doc-xyz")).toBe(
			"/apps/floodgate-todo-list?documentId=doc-xyz",
		);
	});

	it("includes mintCredential in query", () => {
		expect(
			buildAppUrl("floodgate-todo-list", undefined, undefined, "mint-secret"),
		).toBe("/apps/floodgate-todo-list?mintCredential=mint-secret");
	});

	it("includes documentId and mintCredential together", () => {
		const url = buildAppUrl(
			"floodgate-todo-list",
			"doc-1",
			undefined,
			"mint-secret",
		);
		const parsed = new URL(url, "http://localhost");
		expect(parsed.searchParams.get("documentId")).toBe("doc-1");
		expect(parsed.searchParams.get("mintCredential")).toBe("mint-secret");
		expect(parsed.searchParams.has("authToken")).toBe(false);
	});
});
