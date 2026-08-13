import type { SandbagApp } from "./types.js";

export type AppType = string;

/**
 * Lazy loaders for sandbag-compatible apps.
 *
 * Each entry dynamically imports the `./sandbag` entrypoint from an
 * example package. The heavy Fluid Framework code only loads when
 * the user actually opens that app.
 *
 * To add a new app:
 *   1. Add a `./sandbag` export to the package's package.json
 *   2. Add an entry here
 *   3. Add the package as a dependency of @tylerbu/sandbag
 */
const APP_LOADERS: Record<string, () => Promise<SandbagApp>> = {
	"dice-roller": () =>
		import("@tylerbu/levee-example/sandbag").then((m) => m.default),
	presence: () =>
		import("@tylerbu/levee-presence-tracker/sandbag").then((m) => m.default),
	"todo-list": () =>
		import("@tylerbu/levee-todo-list/sandbag").then((m) => m.default),
};

/** All registered app type IDs. */
export const APP_TYPES: string[] = Object.keys(APP_LOADERS);

/** Cache of loaded app descriptors. */
const loaded = new Map<string, SandbagApp>();

/**
 * Dynamically load a sandbag app descriptor by type ID.
 * Results are cached after first load.
 */
export async function loadApp(type: string): Promise<SandbagApp | undefined> {
	const cached = loaded.get(type);
	if (cached) return cached;

	const loader = APP_LOADERS[type];
	if (!loader) return undefined;

	const app = await loader();
	loaded.set(type, app);
	return app;
}

/**
 * Load all app descriptors (for the dashboard).
 */
export async function loadAllApps(): Promise<SandbagApp[]> {
	const entries = await Promise.all(
		APP_TYPES.map(async (type) => {
			const app = await loadApp(type);
			return app;
		}),
	);
	return entries.filter((a): a is SandbagApp => a !== undefined);
}
