import { pack } from "msgpackr";
import { describe, expect, it } from "vitest";
import { decodeMsgpack, encodeMsgpack } from "../src/msgpackSerializer.js";

describe("msgpackSerializer", () => {
	describe("encodeMsgpack", () => {
		it("encodes a message as msgpack binary", () => {
			const msg = {
				join_ref: "1",
				ref: "2",
				topic: "document:tenant:doc1",
				event: "op:submit",
				payload: { data: "hello" },
			};

			encodeMsgpack(msg, (encoded) => {
				expect(encoded).toBeInstanceOf(Uint8Array);
			});
		});

		it("preserves all message fields through encode", () => {
			const msg = {
				join_ref: "j1",
				ref: "r1",
				topic: "my-topic",
				event: "my-event",
				payload: { key: "value" },
			};

			encodeMsgpack(msg, (encoded) => {
				expect(encoded).toBeDefined();
				expect((encoded as Uint8Array).byteLength).toBeGreaterThan(0);
			});
		});

		it("handles null join_ref and ref", () => {
			const msg = {
				join_ref: null,
				ref: null,
				topic: "topic",
				event: "event",
				payload: {},
			};

			encodeMsgpack(msg, (encoded) => {
				expect(encoded).toBeInstanceOf(Uint8Array);
			});
		});
	});

	describe("decodeMsgpack", () => {
		it("decodes a msgpack binary into a message object", () => {
			const original = [
				"1",
				"2",
				"document:tenant:doc1",
				"op:submit",
				{ data: "hello" },
			];
			const packed = pack(original);
			// Convert to ArrayBuffer to simulate WebSocket binary frame
			const arrayBuffer = packed.buffer.slice(
				packed.byteOffset,
				packed.byteOffset + packed.byteLength,
			);

			decodeMsgpack(arrayBuffer, (decoded) => {
				const msg = decoded as {
					join_ref: string;
					ref: string;
					topic: string;
					event: string;
					payload: unknown;
				};
				expect(msg.join_ref).toBe("1");
				expect(msg.ref).toBe("2");
				expect(msg.topic).toBe("document:tenant:doc1");
				expect(msg.event).toBe("op:submit");
				expect(msg.payload).toEqual({ data: "hello" });
			});
		});

		it("handles null join_ref and ref", () => {
			const original = [null, null, "topic", "event", {}];
			const packed = pack(original);
			const arrayBuffer = packed.buffer.slice(
				packed.byteOffset,
				packed.byteOffset + packed.byteLength,
			);

			decodeMsgpack(arrayBuffer, (decoded) => {
				const msg = decoded as { join_ref: unknown; ref: unknown };
				expect(msg.join_ref).toBeNull();
				expect(msg.ref).toBeNull();
			});
		});
	});

	describe("roundtrip", () => {
		it("encode then decode preserves all fields", () => {
			const original = {
				join_ref: "j1",
				ref: "r1",
				topic: "document:t1:d1",
				event: "op:submit",
				payload: { ops: [{ insert: "hello" }] },
			};

			encodeMsgpack(original, (encoded) => {
				const uint8 = encoded as Uint8Array;
				const arrayBuffer = uint8.buffer.slice(
					uint8.byteOffset,
					uint8.byteOffset + uint8.byteLength,
				);

				decodeMsgpack(arrayBuffer, (decoded) => {
					const msg = decoded as typeof original;
					expect(msg.join_ref).toBe(original.join_ref);
					expect(msg.ref).toBe(original.ref);
					expect(msg.topic).toBe(original.topic);
					expect(msg.event).toBe(original.event);
					expect(msg.payload).toEqual(original.payload);
				});
			});
		});

		it("handles complex nested payloads", () => {
			const original = {
				join_ref: "1",
				ref: "2",
				topic: "t",
				event: "e",
				payload: {
					nested: { list: [1, 2, 3], bool: true },
					nullVal: null,
				},
			};

			encodeMsgpack(original, (encoded) => {
				const uint8 = encoded as Uint8Array;
				const arrayBuffer = uint8.buffer.slice(
					uint8.byteOffset,
					uint8.byteOffset + uint8.byteLength,
				);

				decodeMsgpack(arrayBuffer, (decoded) => {
					const msg = decoded as typeof original;
					expect(msg.payload).toEqual(original.payload);
				});
			});
		});
	});
});
