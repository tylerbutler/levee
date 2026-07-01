/**
 * Cutover readiness gate for the Sluice-first migration (ADR-003).
 *
 * This module computes whether the runtime cutover described in
 * `docs/adr/003-sluice-cutover-readiness.md` is allowed to proceed. It is
 * deliberately conservative: readiness is derived from two independent
 * signals that both have to agree before `ready` is `true`.
 *
 *   1. The *actual* state of the conformance suite — counted by scanning
 *      `sluice-routerlicious.test.ts` for outstanding `it.todo(...)` calls.
 *      Each `it.todo` documents a known gap in the create/load/sync/
 *      reconnect/summaries/signals conformance surface required by
 *      ADR-002 for the `sluice-direct` and `levee-proxy` targets.
 *   2. The *declared* state in the repo-tracked `cutover-readiness.json`
 *      manifest, which records the expected todo count and an explicit
 *      `readyForCutover` flag that a human must flip deliberately.
 *
 * If the actual todo count drifts from the manifest's expectation (in
 * either direction), `computeCutoverReadiness()` reports a mismatch so the
 * accompanying test fails loudly — this forces whoever changes the
 * conformance suite to also touch the manifest, rather than silently
 * improving (or regressing) conformance without updating the gate.
 */

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const COMPAT_TEST_FILE = fileURLToPath(
	new URL("./sluice-routerlicious.test.ts", import.meta.url),
);

const MANIFEST_FILE = fileURLToPath(
	new URL("./cutover-readiness.json", import.meta.url),
);

export interface CutoverReadinessManifest {
	adr: string;
	conformanceSuite: string;
	requiredTargets: string[];
	requiredConformanceCategories: string[];
	phoenixOwnedSurfacesPendingRetirement: string[];
	expectedOutstandingTodoCount: number;
	lastVerifiedAt: string;
	readyForCutover: boolean;
	notes: string;
}

export interface CutoverReadiness {
	/** Manifest contents as checked into `cutover-readiness.json`. */
	manifest: CutoverReadinessManifest;
	/** Live count of `it.todo(...)` calls in the conformance suite. */
	actualTodoCount: number;
	/** True when `actualTodoCount` matches the manifest's declared count. */
	manifestMatchesReality: boolean;
	/**
	 * True only when the manifest declares cutover-ready AND there are zero
	 * outstanding conformance gaps. This is the single source of truth
	 * other tooling (docs, CI gates) should consult before treating Sluice
	 * as the standalone primary runtime.
	 */
	ready: boolean;
}

/** Reads and parses the repo-tracked cutover readiness manifest. */
export function readCutoverManifest(): CutoverReadinessManifest {
	const raw = readFileSync(MANIFEST_FILE, "utf8");
	return JSON.parse(raw) as CutoverReadinessManifest;
}

/**
 * Counts outstanding `it.todo(...)` conformance gaps in
 * `sluice-routerlicious.test.ts`. This is a deliberately blunt proxy
 * metric — it does not distinguish which conformance category a given gap
 * belongs to — but it is cheap, hard to fake by accident, and directly
 * tied to the acceptance suite named in ADR-002/ADR-003.
 */
export function countOutstandingConformanceTodos(): number {
	const source = readFileSync(COMPAT_TEST_FILE, "utf8");
	const matches = source.match(/\bit\.todo\(/g) ?? [];
	return matches.length;
}

/** Computes full cutover readiness by combining live and declared state. */
export function computeCutoverReadiness(): CutoverReadiness {
	const manifest = readCutoverManifest();
	const actualTodoCount = countOutstandingConformanceTodos();
	const manifestMatchesReality =
		actualTodoCount === manifest.expectedOutstandingTodoCount;

	return {
		manifest,
		actualTodoCount,
		manifestMatchesReality,
		ready: manifest.readyForCutover && actualTodoCount === 0,
	};
}
