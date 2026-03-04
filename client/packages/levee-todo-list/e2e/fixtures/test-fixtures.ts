import {
	type BrowserContext,
	test as base,
	expect,
	type Page,
} from "@playwright/test";

const CONNECTION_TIMEOUT = 15_000;

export interface TestFixtures {
	connectedPage: Page;
	secondUser: {
		context: BrowserContext;
		page: Page;
	};
}

/**
 * Wait for the page to show "connected" status
 */
export async function waitForConnected(page: Page): Promise<void> {
	await expect(page.locator("#status")).toContainText("Connected:", {
		timeout: CONNECTION_TIMEOUT,
	});
}

/**
 * Wait for the todo-list view to be fully loaded
 */
export async function waitForTodoView(page: Page): Promise<void> {
	await expect(page.locator(".todo-view")).toBeVisible({
		timeout: CONNECTION_TIMEOUT,
	});
}

/**
 * Extract the container ID from the URL hash
 */
export function getContainerIdFromUrl(page: Page): string {
	const hash = new URL(page.url()).hash;
	return hash.replace("#", "");
}

/**
 * Attach console logging from a browser page to Node.js stdout for debugging.
 */
function attachConsoleLogger(page: Page, label: string): void {
	page.on("console", (msg) => {
		const type = msg.type();
		if (type === "error" || type === "warning" || type === "info") {
			// biome-ignore lint/suspicious/noConsole: e2e debugging
			console.log(`[${label}:${type}] ${msg.text()}`);
		}
	});
}

export const test = base.extend<TestFixtures>({
	/**
	 * Provides a page that's already connected to a new container with the todo-list loaded.
	 * Each test gets its own fresh container.
	 */
	connectedPage: async ({ page }, use) => {
		attachConsoleLogger(page, "user1");

		// Navigate to create a new container
		await page.goto("/");

		// Wait for connection and todo view to load
		await waitForConnected(page);
		await waitForTodoView(page);

		// Verify container ID is in the URL
		const containerId = getContainerIdFromUrl(page);
		expect(containerId).toBeTruthy();

		await use(page);
	},

	/**
	 * Creates a second browser context with a unique user identity
	 * that joins the same container as the first user.
	 */
	secondUser: async ({ browser, connectedPage }, use) => {
		// Get the container URL from the first user's page
		const containerUrl = connectedPage.url();

		// Create a new browser context (simulates a different user/session)
		const context = await browser.newContext();
		const page = await context.newPage();
		attachConsoleLogger(page, "user2");

		// Navigate to the same container URL
		await page.goto(containerUrl);

		// Wait for the second user to connect and load
		await waitForConnected(page);
		await waitForTodoView(page);

		await use({ context, page });

		// Cleanup
		await context.close();
	},
});

export { expect };
