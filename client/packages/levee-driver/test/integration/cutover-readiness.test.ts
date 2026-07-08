/**
 * Executable cutover readiness gate (ADR-003).
 *
 * Unlike `floodgate-routerlicious.test.ts`, this suite is NOT network-gated —
 * it runs on every `pnpm test` invocation and only inspects repo-tracked
 * source/data files. Its job is to prevent the project from silently
 * drifting into (or claiming) a Floodgate cutover before conformance and
 * parity are actually met, per:
 *
 *   - ADR-002 (`docs/adr/002-client-compatibility-strategy.md`) — defines
 *     the create/load/sync/reconnect/summaries/signals acceptance surface.
 *   - ADR-003 (`docs/adr/003-floodgate-cutover-readiness.md`) — defines the
 *     cutover gate itself and the Phoenix-owned surfaces that must be
 *     ported or retired before Phoenix/the Socket.IO shim can be removed.
 */

import { describe, expect, it } from "vitest";
import {
	computeCutoverReadiness,
	countOutstandingConformanceTodos,
	readCutoverManifest,
} from "./cutover-readiness.js";

describe("Floodgate cutover readiness gate", () => {
	it("keeps the cutover-readiness.json manifest in sync with the conformance suite", () => {
		const manifest = readCutoverManifest();
		const actualTodoCount = countOutstandingConformanceTodos();

		expect(
			actualTodoCount,
			"The number of `it.todo(...)` gaps in floodgate-routerlicious.test.ts " +
				"changed without updating `expectedOutstandingTodoCount` in " +
				"cutover-readiness.json. Update the manifest (and, if the count " +
				"reached 0, revisit `readyForCutover` and docs/adr/003-floodgate-cutover-readiness.md) " +
				"in the same change that touches the conformance suite.",
		).toBe(manifest.expectedOutstandingTodoCount);
	});

	it("does not consider the runtime cutover ready while conformance gaps remain", () => {
		const readiness = computeCutoverReadiness();

		expect(readiness.manifestMatchesReality).toBe(true);
		expect(readiness.actualTodoCount).toBeGreaterThan(0);
		expect(readiness.manifest.readyForCutover).toBe(false);
		expect(readiness.ready).toBe(false);
	});

	it("requires both floodgate-direct and levee-proxy as gating targets", () => {
		const manifest = readCutoverManifest();

		expect(manifest.requiredTargets).toEqual(
			expect.arrayContaining(["floodgate-direct", "levee-proxy"]),
		);
	});

	it("declares the full create/load/sync/reconnect/summaries/signals surface from ADR-002", () => {
		const manifest = readCutoverManifest();

		expect(manifest.requiredConformanceCategories).toEqual(
			expect.arrayContaining([
				"create",
				"load",
				"sync",
				"reconnect",
				"summaries",
				"signals",
			]),
		);
	});

	it("lists the Phoenix-owned surfaces that still need porting or retirement", () => {
		const manifest = readCutoverManifest();

		expect(
			manifest.phoenixOwnedSurfacesPendingRetirement.length,
		).toBeGreaterThan(0);
		expect(manifest.phoenixOwnedSurfacesPendingRetirement).toEqual(
			expect.arrayContaining([
				"server/lib/levee_web/socket_io_plug.ex",
				"server/lib/levee_web/socket_io_websock.ex",
			]),
		);
	});

	it("would fail loudly if readyForCutover were flipped on without closing every gap", () => {
		// Guards against a manual `readyForCutover: true` edit that isn't
		// backed by an actually-empty conformance gap list. If this ever
		// fails, it means the manifest was hand-edited inconsistently.
		const manifest = readCutoverManifest();

		if (manifest.readyForCutover) {
			expect(manifest.expectedOutstandingTodoCount).toBe(0);
			expect(countOutstandingConformanceTodos()).toBe(0);
		}
	});
});
