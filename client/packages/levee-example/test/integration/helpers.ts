/**
 * Shared helpers for levee-example integration tests.
 */

import { createLeveeDriver } from "../../src/driver.js";

export const LEVEE_HTTP_URL =
	process.env.LEVEE_HTTP_URL ?? "http://localhost:4000";
export const LEVEE_SOCKET_URL =
	process.env.LEVEE_SOCKET_URL ?? "ws://localhost:4000/socket";
export const LEVEE_TENANT_KEY =
	process.env.LEVEE_TENANT_KEY ?? "dev-tenant-secret-key";
export const LEVEE_TENANT_ID = "fluid";

/**
 * Check if the Levee server is reachable. Result is cached for the process lifetime.
 */
let _serverAvailable: boolean | undefined;
export async function isServerRunning(): Promise<boolean> {
	if (_serverAvailable !== undefined) {
		return _serverAvailable;
	}
	try {
		const controller = new AbortController();
		const timeout = setTimeout(() => controller.abort(), 2000);
		const response = await fetch(`${LEVEE_HTTP_URL}/health`, {
			signal: controller.signal,
		});
		clearTimeout(timeout);
		_serverAvailable = response.ok;
	} catch {
		_serverAvailable = false;
	}

	if (!_serverAvailable) {
		console.log(
			"\n⚠️  Levee server not running. Integration tests will be skipped.",
		);
		console.log("   Start the server with: docker compose up -d");
		console.log(`   Expected server at: ${LEVEE_HTTP_URL}\n`);
	}

	return _serverAvailable;
}

/**
 * Create a configured Levee driver for tests.
 */
export function createTestDriver() {
	return createLeveeDriver({
		httpUrl: LEVEE_HTTP_URL,
		socketUrl: LEVEE_SOCKET_URL,
		tenantKey: LEVEE_TENANT_KEY,
		user: {
			id: "integration-test-user",
			name: "Integration Test",
		},
	});
}
