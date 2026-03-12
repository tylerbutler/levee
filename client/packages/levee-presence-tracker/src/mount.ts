/**
 * Sandbag-compatible mount function for embedding the Presence Tracker app.
 */

import { getPresence } from "@fluidframework/presence/alpha";
import { LeveeClient } from "@tylerbu/levee-client";
import type { IFluidContainer } from "fluid-framework";
import type { PresenceTrackerSchema } from "./app.js";
import { EmptyDOEntry } from "./datastoreFactory.js";
import { FocusTracker } from "./FocusTracker.js";
import { MouseTracker } from "./MouseTracker.js";
import { initializeReactions } from "./reactions.js";
import {
	renderControlPanel,
	renderFocusPresence,
	renderMousePresence,
} from "./view.js";

export interface MountConfig {
	httpUrl?: string;
	socketUrl?: string;
	tenantKey?: string;
	authToken?: string;
	documentId?: string;
	appName?: string;
	appVersion?: string;
}

const containerSchema = {
	initialObjects: {
		nothing: EmptyDOEntry,
	},
} satisfies import("fluid-framework").ContainerSchema;

/**
 * Mount the Presence Tracker app into a DOM element.
 *
 * Creates the necessary DOM structure inside the provided element,
 * connects to Levee, and initializes focus/mouse tracking.
 *
 * @param element - The DOM element to render into.
 * @param config - Connection configuration. If `documentId` is provided,
 *   loads an existing container; otherwise creates a new one.
 * @returns An object with `unmount` to clean up and `documentId` of the loaded/created container.
 */
export async function mount(
	element: HTMLElement,
	config: MountConfig = {},
): Promise<{ unmount: () => void; documentId: string }> {
	const httpUrl = config.httpUrl ?? "http://localhost:4000";
	const socketUrl = config.socketUrl ?? "ws://localhost:4000/socket";

	// Build the DOM structure the app expects
	element.innerHTML = `
		<div id="pt-status" style="padding: 8px 16px; font-size: 14px; background: #f0f0f0; border-radius: 4px; margin-bottom: 8px;">Connecting...</div>
		<div id="pt-control-panel" style="padding: 10px"></div>
		<div id="pt-focus-content" style="min-height: 200px; border: 1px solid #ccc; border-radius: 4px;"></div>
		<div id="pt-mouse-position" style="position: relative; min-height: 300px;"></div>
		<style>
			.reaction { position: absolute; font-size: x-large; animation: fadeUp 1s forwards; }
			@keyframes fadeUp { 0% { opacity: 1; transform: translateY(0) rotate(45deg); } 100% { opacity: 0; transform: translateY(-50px) rotate(-45deg); } }
			emoji-picker { --num-columns: 6; width: 300px; height: 200px; }
		</style>
	`;

	const statusDiv = element.querySelector("#pt-status") as HTMLDivElement;

	function setStatus(message: string, isError = false, isConnected = false) {
		statusDiv.textContent = message;
		statusDiv.style.background = isError
			? "#f8d7da"
			: isConnected
				? "#d4edda"
				: "#f0f0f0";
		statusDiv.style.color = isError
			? "#721c24"
			: isConnected
				? "#155724"
				: "inherit";
	}

	const userId = `user-${Date.now()}-${Math.random().toString(36).slice(2, 7)}`;

	const connectionConfig: import("@tylerbu/levee-client").LeveeConnectionConfig =
		config.authToken
			? {
					httpUrl,
					socketUrl,
					authToken: config.authToken,
				}
			: {
					httpUrl,
					socketUrl,
					tenantKey: config.tenantKey ?? "dev-tenant-secret-key",
					user: { id: userId, name: `User ${userId.slice(-5)}` },
				};

	const client = new LeveeClient({ connection: connectionConfig });

	let container: IFluidContainer<typeof containerSchema>;
	let documentId: string;

	if (config.documentId) {
		documentId = config.documentId;
		setStatus(`Loading container ${documentId}...`);
		({ container } = await client.getContainer(
			documentId,
			containerSchema,
			"2",
		));
	} else {
		setStatus("Creating new container...");
		({ container } = await client.createContainer(containerSchema, "2", {
			...(config.appName ? { appName: config.appName } : {}),
			...(config.appVersion ? { appVersion: config.appVersion } : {}),
		}));
		documentId = await container.attach();
	}

	setStatus(`Connected: ${documentId}`, false, true);

	const presence = getPresence(container);
	const appPresence = presence.states.getWorkspace("name:trackerData", {});

	const focusTracker = new FocusTracker(presence, appPresence);
	const mouseTracker = new MouseTracker(presence, appPresence);
	initializeReactions(presence, mouseTracker);

	const focusDiv = element.querySelector("#pt-focus-content") as HTMLDivElement;
	renderFocusPresence(focusTracker, focusDiv);

	const mouseDiv = element.querySelector(
		"#pt-mouse-position",
	) as HTMLDivElement;
	renderMousePresence(mouseTracker, focusTracker, mouseDiv);

	const controlDiv = element.querySelector(
		"#pt-control-panel",
	) as HTMLDivElement;
	renderControlPanel(mouseTracker, controlDiv);

	return {
		unmount: () => {
			container.dispose();
			element.innerHTML = "";
		},
		documentId,
	};
}
