import { LeveeClient } from "@tylerbu/levee-client";
import type { IFluidContainer } from "fluid-framework";
import { createRoot } from "react-dom/client";

import {
	initializeAppForNewContainer,
	loadAppFromExistingContainer,
	type TodoListContainerSchema,
	todoListContainerSchema,
} from "./fluid.js";
import type { TodoList } from "./schema.js";
import { TodoListAppView } from "./view.js";

// Default configuration values
// In dev mode, requests are proxied through Vite to avoid CORS issues
const LEVEE_HTTP_URL =
	import.meta.env["VITE_LEVEE_HTTP_URL"] ||
	(import.meta.env.DEV ? window.location.origin : "http://localhost:4000");
const LEVEE_SOCKET_URL =
	import.meta.env["VITE_LEVEE_SOCKET_URL"] ||
	(import.meta.env.DEV
		? `ws://${window.location.host}/socket`
		: "ws://localhost:4000/socket");
const LEVEE_TENANT_KEY =
	import.meta.env["VITE_LEVEE_TENANT_KEY"] || "dev-tenant-secret-key";

/**
 * Updates the status indicator in the UI.
 */
function setStatus(
	message: string,
	isError = false,
	isConnected = false,
): void {
	const statusDiv = document.querySelector("#status");
	if (statusDiv) {
		statusDiv.textContent = message;
		statusDiv.className = isError ? "error" : isConnected ? "connected" : "";
	}
}

/**
 * Start the todo-list app.
 */
async function start(): Promise<void> {
	setStatus("Connecting to Levee server...");

	// Create a unique user ID for this session
	const userId = `user-${Date.now()}-${Math.random().toString(36).slice(2, 7)}`;

	const client = new LeveeClient({
		connection: {
			httpUrl: LEVEE_HTTP_URL,
			socketUrl: LEVEE_SOCKET_URL,
			tenantKey: LEVEE_TENANT_KEY,
			user: {
				id: userId,
				name: `User ${userId.slice(-5)}`,
			},
		},
	});

	let container: IFluidContainer<TodoListContainerSchema>;
	let containerId: string;
	let appModel: TodoList;

	const createNew = location.hash.length === 0;
	if (createNew) {
		setStatus("Creating new container...");
		({ container } = await client.createContainer(
			todoListContainerSchema,
			"2",
		));

		// Initialize the app model for the new container
		appModel = await initializeAppForNewContainer(container);

		// Attach the container to the service
		containerId = await container.attach();

		// Update the URL hash with the container ID
		location.hash = containerId;
	} else {
		containerId = location.hash.slice(1);
		setStatus(`Loading container ${containerId}...`);

		({ container } = await client.getContainer(
			containerId,
			todoListContainerSchema,
			"2",
		));
		appModel = loadAppFromExistingContainer(container);
	}

	setStatus(`Connected: ${containerId}`, false, true);
	document.title = `Todo List - ${containerId}`;

	// Render the React application
	const contentDiv = document.querySelector("#content") as HTMLDivElement;
	const root = createRoot(contentDiv);
	root.render(<TodoListAppView todoList={appModel} container={container} />);

	console.info("Connected to Levee server");
	console.info("Container ID:", containerId);
	console.info("User ID:", userId);
}

// Start the application
start().catch((error) => {
	console.error("Failed to start application:", error);
	setStatus(
		`Error: ${error instanceof Error ? error.message : String(error)}`,
		true,
	);
});
