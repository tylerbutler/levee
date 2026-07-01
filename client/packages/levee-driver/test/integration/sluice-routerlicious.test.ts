/**
 * Routerlicious driver compatibility checks for Sluice.
 *
 * These tests define the next compatibility milestone: an unmodified official
 * Routerlicious driver should be able to use Sluice's Socket.IO/dewdrop realtime
 * endpoint. The networked test is opt-in because Sluice is not part of the
 * default Levee Docker integration environment.
 */

import type { IResolvedUrl } from "@fluidframework/driver-definitions/internal";
import type { IClient } from "@fluidframework/protocol-definitions";
import { RouterliciousDocumentServiceFactory } from "@fluidframework/routerlicious-driver/internal";
import { describe, expect, it } from "vitest";
import { InsecureLeveeTokenProvider } from "../../src/tokenProvider.js";
import { uniqueDocId } from "./helpers.js";

const SLUICE_HTTP_URL = (
	process.env["SLUICE_HTTP_URL"] ?? "http://localhost:3000"
).replace(/\/$/, "");
const SLUICE_SOCKET_URL = process.env["SLUICE_SOCKET_URL"] ?? SLUICE_HTTP_URL;
const SLUICE_TENANT_ID = process.env["SLUICE_TENANT_ID"] ?? "fluid";
const SLUICE_JWT_SECRET = process.env["SLUICE_JWT_SECRET"] ?? "";
const RUN_ROUTERLICIOUS_COMPAT =
	process.env["SLUICE_ROUTERLICIOUS_COMPAT"] === "1" ||
	process.env["SLUICE_ROUTERLICIOUS_COMPAT"] === "true";

function createSluiceResolvedUrl(documentId: string): IResolvedUrl {
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

async function isSluiceRunning(): Promise<boolean> {
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

const sluiceAvailable = RUN_ROUTERLICIOUS_COMPAT
	? await isSluiceRunning()
	: false;

const testClient: IClient = {
	mode: "write",
	details: {
		capabilities: { interactive: true },
		environment: "node:vitest",
	},
	permission: [],
	user: { id: "routerlicious-compat-user" },
	scopes: ["doc:read", "doc:write", "summary:write"],
};

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

	it.runIf(sluiceAvailable)(
		"connects an unmodified Routerlicious delta stream to Sluice",
		{ timeout: 30_000 },
		async () => {
			const documentId = uniqueDocId("sluice-routerlicious");
			const tokenProvider = new InsecureLeveeTokenProvider(
				SLUICE_JWT_SECRET,
				{
					id: "routerlicious-compat-user",
					name: "Routerlicious Compat User",
				},
				SLUICE_TENANT_ID,
			);
			const factory = new RouterliciousDocumentServiceFactory(tokenProvider, {
				enableDiscovery: false,
				enableLongPollingDowngrade: false,
			});
			const resolvedUrl = createSluiceResolvedUrl(documentId);
			const service = await factory.createDocumentService(resolvedUrl);

			const connection = await service.connectToDeltaStream(testClient);

			expect(connection.clientId).toBeDefined();
			expect(connection.mode).toBe("write");

			connection.dispose();
		},
	);
});
