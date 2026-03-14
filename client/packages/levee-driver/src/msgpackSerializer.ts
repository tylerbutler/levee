/**
 * MessagePack encode/decode functions for Phoenix Socket.
 *
 * @remarks
 * These functions match the `encode` and `decode` option interface expected
 * by the Phoenix JS client's Socket constructor. When used together with
 * `vsn: "3.0.0"`, the server selects the matching MsgpackSerializer.
 *
 * Wire format: a msgpack-encoded array `[join_ref, ref, topic, event, payload]`.
 *
 * @packageDocumentation
 */

import { pack, unpack } from "msgpackr";

/**
 * Shape of a Phoenix channel message used by the Socket's encode/decode hooks.
 */
interface PhoenixMessage {
	join_ref: string | null;
	ref: string | null;
	topic: string;
	event: string;
	payload: unknown;
}

/**
 * Encodes a Phoenix message as a msgpack binary payload.
 *
 * @param msg - The message to encode
 * @param callback - Callback receiving the encoded Uint8Array
 */
export function encodeMsgpack(
	msg: object,
	callback: (encoded: unknown) => void,
): void {
	const m = msg as PhoenixMessage;
	const data = pack([m.join_ref, m.ref, m.topic, m.event, m.payload]);
	callback(data);
}

/**
 * Decodes a msgpack binary payload into a Phoenix message.
 *
 * @param rawPayload - The raw binary data from the WebSocket
 * @param callback - Callback receiving the decoded message
 */
export function decodeMsgpack(
	rawPayload: unknown,
	callback: (decoded: object) => void,
): void {
	const decoded = unpack(new Uint8Array(rawPayload as ArrayBuffer)) as [
		string | null,
		string | null,
		string,
		string,
		unknown,
	];
	callback({
		join_ref: decoded[0],
		ref: decoded[1],
		topic: decoded[2],
		event: decoded[3],
		payload: decoded[4],
	});
}
