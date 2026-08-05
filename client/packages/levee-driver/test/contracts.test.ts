import { describe, expect, it } from "vitest";
import { normalizeNackPayload } from "../src/contracts.js";

describe("contracts", () => {
	describe("normalizeNackPayload", () => {
		const nack = {
			operation: null,
			sequenceNumber: -1,
			content: {
				code: 400,
				type: "BadRequestError",
				message: "Client not connected",
			},
		};

		it("passes through a bare array of nacks", () => {
			expect(normalizeNackPayload([nack])).toEqual([nack]);
		});

		it("unwraps a { clientId, nacks } envelope", () => {
			expect(normalizeNackPayload({ clientId: "", nacks: [nack] })).toEqual([
				nack,
			]);
		});

		it("wraps a single nack object in an array", () => {
			expect(normalizeNackPayload(nack)).toEqual([nack]);
		});

		it("normalizes snake_case keys", () => {
			const raw = {
				client_id: "abc",
				nacks: [
					{
						operation: null,
						sequence_number: 7,
						content: {
							code: 429,
							type: "ThrottlingError",
							message: "slow down",
							retry_after: 5,
						},
					},
				],
			};

			expect(normalizeNackPayload(raw)).toEqual([
				{
					operation: null,
					sequenceNumber: 7,
					content: {
						code: 429,
						type: "ThrottlingError",
						message: "slow down",
						retryAfter: 5,
					},
				},
			]);
		});

		it("returns an empty array for non-object payloads", () => {
			expect(normalizeNackPayload(undefined)).toEqual([]);
			expect(normalizeNackPayload(null)).toEqual([]);
			expect(normalizeNackPayload("garbage")).toEqual([]);
			expect(normalizeNackPayload(42)).toEqual([]);
		});

		it("returns an empty array when nacks is not an array", () => {
			expect(normalizeNackPayload({ clientId: "", nacks: "nope" })).toEqual([]);
		});

		it("returns an empty array for objects that are not nacks", () => {
			expect(normalizeNackPayload({ foo: "bar" })).toEqual([]);
		});
	});
});
