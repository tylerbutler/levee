import { test as base, expect, type Page } from "@playwright/test";

const BASE_URL = "http://localhost:4000";

interface TestUser {
	email: string;
	password: string;
	displayName: string;
}

export interface AdminFixtures {
	testUser: TestUser;
	authenticatedPage: Page;
}

function generateTestUser(): TestUser {
	const id = `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
	return {
		email: `admin-${id}@test.example.com`,
		password: "testpassword123",
		displayName: `Test User ${id}`,
	};
}

async function registerViaApi(user: TestUser): Promise<void> {
	const response = await fetch(`${BASE_URL}/api/auth/register`, {
		method: "POST",
		headers: { "Content-Type": "application/json" },
		body: JSON.stringify({
			email: user.email,
			password: user.password,
			display_name: user.displayName,
		}),
	});

	if (!response.ok) {
		const body = await response.text();
		throw new Error(`Failed to register test user: ${response.status} ${body}`);
	}
}

async function loginViaUi(page: Page, user: TestUser): Promise<void> {
	await page.goto("/admin/login");
	await page.locator("#email").fill(user.email);
	await page.locator("#password").fill(user.password);
	await page.locator('button[type="submit"]').click();
	await expect(page.locator(".authenticated-layout")).toBeVisible({
		timeout: 10_000,
	});
}

export const test = base.extend<AdminFixtures>({
	testUser: async ({}, use) => {
		const user = generateTestUser();
		await use(user);
	},

	authenticatedPage: async ({ page, testUser }, use) => {
		await registerViaApi(testUser);
		await loginViaUi(page, testUser);
		await use(page);
	},
});

export { expect };
