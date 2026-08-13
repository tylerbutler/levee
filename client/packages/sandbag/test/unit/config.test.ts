/**
 * Unit tests for Sandbag URL/config helpers.
 *
 * Verifies that parseConfigFromParams correctly parses all known parameters
 * from URL search params.
 */

import { describe, expect, it } from "vitest";

import { parseConfigFromParams } from "../../src/lib/config.js";

describe("parseConfigFromParams — defaults", () => {
	it("httpUrl is undefined when not in params", () => {
		const config = parseConfigFromParams(new URLSearchParams());
		expect(config.httpUrl).toBeUndefined();
	});

	it("socketUrl is undefined when not in params", () => {
		const config = parseConfigFromParams(new URLSearchParams());
		expect(config.socketUrl).toBeUndefined();
	});

	it("tenantId is undefined when not in params", () => {
		const config = parseConfigFromParams(new URLSearchParams());
		expect(config.tenantId).toBeUndefined();
	});

	it("authToken is undefined when not in params", () => {
		const config = parseConfigFromParams(new URLSearchParams());
		expect(config.authToken).toBeUndefined();
	});

	it("documentId is undefined when not in params", () => {
		const config = parseConfigFromParams(new URLSearchParams());
		expect(config.documentId).toBeUndefined();
	});
});

describe("parseConfigFromParams — explicit values", () => {
	it("parses httpUrl override", () => {
		const config = parseConfigFromParams(
			new URLSearchParams("httpUrl=http://custom:9000"),
		);
		expect(config.httpUrl).toBe("http://custom:9000");
	});

	it("parses socketUrl override", () => {
		const config = parseConfigFromParams(
			new URLSearchParams("socketUrl=ws://custom:9000/socket"),
		);
		expect(config.socketUrl).toBe("ws://custom:9000/socket");
	});

	it("parses tenantId override", () => {
		const config = parseConfigFromParams(
			new URLSearchParams("tenantId=my-tenant"),
		);
		expect(config.tenantId).toBe("my-tenant");
	});

	it("parses authToken", () => {
		const config = parseConfigFromParams(
			new URLSearchParams("authToken=tok-abc"),
		);
		expect(config.authToken).toBe("tok-abc");
	});

	it("parses documentId", () => {
		const config = parseConfigFromParams(
			new URLSearchParams("documentId=doc-123"),
		);
		expect(config.documentId).toBe("doc-123");
	});
});
