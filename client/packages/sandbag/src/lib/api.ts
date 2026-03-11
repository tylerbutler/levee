import { base } from "$app/paths";

export interface SandbagRecord {
	id: string;
	name: string;
	appType: string;
	documentId: string;
	createdAt: string;
}

const STORAGE_KEY = "sandbag:instances";

/**
 * Load all sandbag records from localStorage.
 */
export function listSandbags(): SandbagRecord[] {
	if (typeof localStorage === "undefined") return [];
	const raw = localStorage.getItem(STORAGE_KEY);
	if (!raw) return [];
	try {
		return JSON.parse(raw) as SandbagRecord[];
	} catch {
		return [];
	}
}

/**
 * Get a single sandbag record by ID.
 */
export function getSandbag(id: string): SandbagRecord | undefined {
	return listSandbags().find((s) => s.id === id);
}

/**
 * Create a new sandbag record. The actual Levee document is created
 * lazily when the app page mounts (no documentId needed upfront).
 */
export function createSandbag(name: string, appType: string): SandbagRecord {
	const record: SandbagRecord = {
		id: crypto.randomUUID(),
		name,
		appType,
		documentId: "",
		createdAt: new Date().toISOString(),
	};
	const all = listSandbags();
	all.push(record);
	localStorage.setItem(STORAGE_KEY, JSON.stringify(all));
	return record;
}

/**
 * Update a sandbag record (e.g., to set the documentId after creation).
 */
export function updateSandbag(
	id: string,
	updates: Partial<Pick<SandbagRecord, "documentId" | "name">>,
): void {
	const all = listSandbags();
	const idx = all.findIndex((s) => s.id === id);
	if (idx >= 0) {
		all[idx] = { ...all[idx], ...updates };
		localStorage.setItem(STORAGE_KEY, JSON.stringify(all));
	}
}

/**
 * Delete a sandbag record.
 */
export function deleteSandbag(id: string): void {
	const all = listSandbags().filter((s) => s.id !== id);
	localStorage.setItem(STORAGE_KEY, JSON.stringify(all));
}

/**
 * Build the iframe URL for a given app type, pointing to the
 * SvelteKit app page under /sandbag/apps/{type}.
 */
export function buildAppUrl(appType: string, documentId?: string): string {
	const params = new URLSearchParams();
	if (documentId) {
		params.set("documentId", documentId);
	}
	const query = params.toString();
	return `${base}/apps/${appType}${query ? `?${query}` : ""}`;
}
