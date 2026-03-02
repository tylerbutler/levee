/**
 * Integration tests for DiceRoller container lifecycle.
 *
 * These tests require a running Levee server. Start it with:
 *   pnpm test:integration:up
 *
 * Or run the full integration test suite with:
 *   pnpm test:integration
 *
 * Tests that need the server are wrapped in `describe.runIf(serverAvailable)`
 * and will be properly marked as SKIPPED when the server is not reachable.
 */

import { Loader } from "@fluidframework/container-loader/legacy";
import { beforeAll, describe, expect, it } from "vitest";

import {
	DiceRollerContainerCodeDetails,
	DiceRollerContainerFactory,
	getDiceRollerFromContainer,
} from "../../src/containerCode.js";
import { createLeveeDriver } from "../../src/driver.js";
import {
	createTestDriver,
	isServerRunning,
	LEVEE_HTTP_URL,
	LEVEE_SOCKET_URL,
} from "./helpers.js";

const serverAvailable = await isServerRunning();

describe("Container Lifecycle", () => {
	let driver: ReturnType<typeof createTestDriver>;
	let loader: Loader;

	beforeAll(() => {
		driver = createTestDriver();

		loader = new Loader({
			urlResolver: driver.urlResolver,
			documentServiceFactory: driver.documentServiceFactory,
			codeLoader: {
				load: async () => ({
					module: { fluidExport: DiceRollerContainerFactory },
					details: DiceRollerContainerCodeDetails,
				}),
			},
		});
	});

	describe.runIf(serverAvailable)("Create and Load", () => {
		it("creates a new container", { timeout: 30_000 }, async () => {
			const documentId = `test-create-${Date.now()}`;
			const request = driver.createCreateNewRequest(documentId);

			const container = await loader.createDetachedContainer(
				DiceRollerContainerCodeDetails,
			);
			await container.attach(request);

			expect(container.closed).toBe(false);
			expect(container.attachState).toBe("attached");

			container.dispose();
		});

		it("loads an existing container", { timeout: 30_000 }, async () => {
			// First create a container
			const documentId = `test-load-${Date.now()}`;
			const createRequest = driver.createCreateNewRequest(documentId);
			const container1 = await loader.createDetachedContainer(
				DiceRollerContainerCodeDetails,
			);
			await container1.attach(createRequest);

			// Then load it
			const loadRequest = driver.createLoadExistingRequest(documentId);
			const container2 = await loader.resolve(loadRequest);

			expect(container2.closed).toBe(false);
			expect(container2.attachState).toBe("attached");

			container1.dispose();
			container2.dispose();
		});

		it("gets DiceRoller from container", { timeout: 30_000 }, async () => {
			const documentId = `test-diceroller-${Date.now()}`;
			const request = driver.createCreateNewRequest(documentId);

			const container = await loader.createDetachedContainer(
				DiceRollerContainerCodeDetails,
			);
			await container.attach(request);

			const diceRoller = await getDiceRollerFromContainer(container);
			expect(diceRoller).toBeDefined();
			expect(diceRoller.value).toBe(1); // Initial value

			container.dispose();
		});
	});

	describe.runIf(serverAvailable)("Collaborative Sync", () => {
		it(
			"synchronizes dice rolls between clients",
			{ timeout: 30_000 },
			async () => {
				const documentId = `test-sync-${Date.now()}`;

				// Create first client
				const createRequest = driver.createCreateNewRequest(documentId);
				const container1 = await loader.createDetachedContainer(
					DiceRollerContainerCodeDetails,
				);
				await container1.attach(createRequest);
				const diceRoller1 = await getDiceRollerFromContainer(container1);

				// Create second client that loads the same document
				const loadRequest = driver.createLoadExistingRequest(documentId);
				const container2 = await loader.resolve(loadRequest);
				const diceRoller2 = await getDiceRollerFromContainer(container2);

				// Both should start with the same value
				expect(diceRoller1.value).toBe(diceRoller2.value);

				// Roll on client 1
				diceRoller1.roll();

				// Wait for sync with polling (more reliable than fixed timeout)
				const rolledValue = diceRoller1.value;
				await new Promise<void>((resolve, reject) => {
					const deadline = Date.now() + 5000;
					const check = () => {
						if (diceRoller2.value === rolledValue) {
							resolve();
						} else if (Date.now() > deadline) {
							reject(
								new Error(
									`Sync timeout: client1=${rolledValue}, client2=${diceRoller2.value}`,
								),
							);
						} else {
							setTimeout(check, 100);
						}
					};
					check();
				});

				expect(diceRoller2.value).toBe(rolledValue);

				container1.dispose();
				container2.dispose();
			},
		);
	});
});

describe("Driver Configuration", () => {
	it("creates driver with test configuration", () => {
		const driver = createLeveeDriver({
			httpUrl: LEVEE_HTTP_URL,
			socketUrl: LEVEE_SOCKET_URL,
			tenantKey: "dev-tenant-secret-key",
		});

		expect(driver.config.httpUrl).toBe(LEVEE_HTTP_URL);
		expect(driver.config.socketUrl).toBe(LEVEE_SOCKET_URL);
	});
});
