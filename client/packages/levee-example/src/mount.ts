/**
 * Sandbag-compatible mount function for embedding the DiceRoller app.
 */

import type { IContainer } from "@fluidframework/container-definitions/legacy";
import { Loader } from "@fluidframework/container-loader/legacy";
import { createElement } from "react";
import { createRoot, type Root } from "react-dom/client";

import {
	DiceRollerContainerCodeDetails,
	DiceRollerContainerFactory,
	getDiceRollerFromContainer,
} from "./containerCode.js";
import { DiceRollerView } from "./diceRoller.js";
import { createLeveeDriver } from "./driver.js";

export interface MountConfig {
	httpUrl?: string;
	socketUrl?: string;
	tenantKey?: string;
	tenantId?: string;
	documentId?: string;
}

/**
 * Mount the DiceRoller app into a DOM element.
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
	const driver = createLeveeDriver(config);

	const loader = new Loader({
		urlResolver: driver.urlResolver,
		documentServiceFactory: driver.documentServiceFactory,
		codeLoader: {
			load: async () => ({
				module: { fluidExport: DiceRollerContainerFactory },
				details: DiceRollerContainerCodeDetails,
			}),
		},
	});

	let documentId = config.documentId;
	let container: IContainer;

	if (documentId) {
		const request = driver.createLoadExistingRequest(documentId);
		container = await loader.resolve(request);
	} else {
		documentId = generateDocumentId();
		const request = driver.createCreateNewRequest(documentId);
		container = await loader.createDetachedContainer(
			DiceRollerContainerCodeDetails,
		);
		await container.attach(request);
	}

	const diceRoller = await getDiceRollerFromContainer(container);

	const root: Root = createRoot(element);
	root.render(createElement(DiceRollerView, { diceRoller }));

	return {
		unmount: () => {
			root.unmount();
			container.close();
		},
		documentId,
	};
}

function generateDocumentId(): string {
	const chars = "abcdefghijklmnopqrstuvwxyz0123456789";
	let result = "";
	for (let i = 0; i < 12; i++) {
		result += chars[Math.floor(Math.random() * chars.length)];
	}
	return result;
}
