/**
 * Interface for a sandbag-compatible app.
 *
 * Each example package exports a default object matching this shape
 * from its `./sandbag` subpath export.
 */
export interface SandbagApp {
	/** Unique identifier, e.g., "dice-roller" */
	id: string;
	/** Human-readable name, e.g., "Dice Roller" */
	label: string;
	/** Emoji icon */
	icon: string;
	/** Short description */
	description: string;
	/** Mount the app into a DOM element. Returns cleanup + the created documentId. */
	mount: (
		element: HTMLElement,
		config: SandbagMountConfig,
	) => Promise<SandbagMountResult>;
}

export interface SandbagMountConfig {
	httpUrl?: string;
	socketUrl?: string;
	tenantKey?: string;
	tenantId?: string;
	authToken?: string;
	documentId?: string;
}

export interface SandbagMountResult {
	unmount: () => void;
	documentId: string;
}
