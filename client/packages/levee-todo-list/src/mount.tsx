/**
 * Sandbag-compatible mount function for embedding the TodoList app.
 */

import { LeveeClient } from "@tylerbu/levee-client";
import type { IFluidContainer } from "fluid-framework";
import { createElement } from "react";
import { createRoot, type Root } from "react-dom/client";

import {
	initializeAppForNewContainer,
	loadAppFromExistingContainer,
	type TodoListContainerSchema,
	todoListContainerSchema,
} from "./fluid.js";
import { TodoListAppView } from "./view.js";

export interface MountConfig {
	httpUrl?: string;
	socketUrl?: string;
	tenantKey?: string;
	authToken?: string;
	documentId?: string;
	appName?: string;
	appVersion?: string;
}

/**
 * Mount the TodoList app into a DOM element.
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

	let container: IFluidContainer<TodoListContainerSchema>;
	let documentId: string;

	if (config.documentId) {
		documentId = config.documentId;
		({ container } = await client.getContainer(
			documentId,
			todoListContainerSchema,
			"2",
		));
	} else {
		({ container } = await client.createContainer(
			todoListContainerSchema,
			"2",
			{
				appName: config.appName,
				appVersion: config.appVersion,
			},
		));
		documentId = await container.attach();
	}

	const appModel = config.documentId
		? loadAppFromExistingContainer(container)
		: await initializeAppForNewContainer(container);

	const root: Root = createRoot(element);
	root.render(
		createElement(TodoListAppView, { todoList: appModel, container }),
	);

	return {
		unmount: () => {
			root.unmount();
			container.dispose();
		},
		documentId,
	};
}
