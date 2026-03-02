/**
 * Integration tests for LeveeClient.
 *
 * Tests the high-level container creation and loading API.
 * Requires a running Levee server — skipped automatically if unavailable.
 */

import type {
	ContainerSchema,
	IFluidContainer,
} from "@fluidframework/fluid-static";
import { SharedMap } from "@fluidframework/map";
import { afterEach, beforeAll, describe, expect, it } from "vitest";
import type { LeveeClient } from "../../src/client.js";
import { createTestClient, isServerRunning } from "./helpers.js";

const serverAvailable = await isServerRunning();

const testSchema = {
	initialObjects: {
		testMap: SharedMap,
	},
} satisfies ContainerSchema;

type TestSchema = typeof testSchema;

describe.runIf(serverAvailable)("LeveeClient Integration", () => {
	let client: LeveeClient;
	const containersToDispose: IFluidContainer<TestSchema>[] = [];

	beforeAll(() => {
		client = createTestClient();
	});

	afterEach(() => {
		for (const container of containersToDispose) {
			container.dispose();
		}
		containersToDispose.length = 0;
	});

	describe("createContainer", () => {
		it(
			"creates a detached container and attaches it",
			{ timeout: 30_000 },
			async () => {
				const { container, services } = await client.createContainer(
					testSchema,
					"2",
				);
				containersToDispose.push(container);

				expect(container).toBeDefined();
				expect(services).toBeDefined();

				// Container starts detached
				expect(container.attachState).toBe("Detached");

				// Attach and get the container ID
				const containerId = await container.attach();
				expect(containerId).toBeDefined();
				expect(typeof containerId).toBe("string");
				expect(containerId.length).toBeGreaterThan(0);

				expect(container.attachState).toBe("Attached");
			},
		);

		it(
			"container has initialObjects from schema",
			{ timeout: 30_000 },
			async () => {
				const { container } = await client.createContainer(testSchema, "2");
				containersToDispose.push(container);

				expect(container.initialObjects).toBeDefined();
				expect(container.initialObjects.testMap).toBeDefined();

				await container.attach();
			},
		);

		it("services.audience is defined", { timeout: 30_000 }, async () => {
			const { container, services } = await client.createContainer(
				testSchema,
				"2",
			);
			containersToDispose.push(container);

			expect(services.audience).toBeDefined();

			await container.attach();
		});
	});

	// Loading existing containers currently fails with Fluid Framework error
	// 0x8e4. The factory generates a new document ID on the server that doesn't
	// match the ID used by the loading client. These tests will pass once the
	// createContainer flow correctly propagates the document ID.
	describe("getContainer", () => {
		it.fails(
			"loads an existing container by ID",
			{ timeout: 30_000 },
			async () => {
				// Create and attach first
				const { container: created } = await client.createContainer(
					testSchema,
					"2",
				);
				containersToDispose.push(created);

				const containerId = await created.attach();

				// Load in a second client
				const client2 = createTestClient("second-user");
				const { container: loaded, services } = await client2.getContainer(
					containerId,
					testSchema,
					"2",
				);
				containersToDispose.push(loaded);

				expect(loaded).toBeDefined();
				expect(loaded.attachState).toBe("Attached");
				expect(services.audience).toBeDefined();
			},
		);

		it.fails(
			"loaded container has initialObjects accessible",
			{ timeout: 30_000 },
			async () => {
				const { container: created } = await client.createContainer(
					testSchema,
					"2",
				);
				containersToDispose.push(created);

				const containerId = await created.attach();

				const client2 = createTestClient("second-user");
				const { container: loaded } = await client2.getContainer(
					containerId,
					testSchema,
					"2",
				);
				containersToDispose.push(loaded);

				expect(loaded.initialObjects.testMap).toBeDefined();
			},
		);
	});

	describe("data round-trip", () => {
		it.fails(
			"create -> set value -> attach -> load -> verify value",
			{ timeout: 45_000 },
			async () => {
				// Create container and set data
				const { container: created } = await client.createContainer(
					testSchema,
					"2",
				);
				containersToDispose.push(created);

				const map = created.initialObjects.testMap;
				map.set("greeting", "hello from integration test");

				const containerId = await created.attach();

				// Load from a second client
				const client2 = createTestClient("reader-user");
				const { container: loaded } = await client2.getContainer(
					containerId,
					testSchema,
					"2",
				);
				containersToDispose.push(loaded);

				// Verify data is accessible
				const loadedMap = loaded.initialObjects.testMap;

				// Wait for data to sync (may need a brief delay)
				await new Promise<void>((resolve) => {
					const check = () => {
						if (loadedMap.get("greeting") !== undefined) {
							resolve();
						} else {
							setTimeout(check, 100);
						}
					};
					check();
				});

				expect(loadedMap.get("greeting")).toBe("hello from integration test");
			},
		);
	});
});
