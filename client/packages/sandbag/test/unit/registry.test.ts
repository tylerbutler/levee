import { describe, expect, it } from "vitest";

import { APP_TYPES, loadApp } from "../../src/lib/registry.js";

describe("APP_TYPES registry", () => {
	it("contains the Levee examples", () => {
		expect(APP_TYPES).toEqual(["dice-roller", "presence", "todo-list"]);
	});

	it("loads the todo-list descriptor", async () => {
		const app = await loadApp("todo-list");
		expect(app?.id).toBe("todo-list");
		expect(typeof app?.mount).toBe("function");
	});

	it("returns undefined for an unknown app type", async () => {
		expect(await loadApp("unknown")).toBeUndefined();
	});
});
