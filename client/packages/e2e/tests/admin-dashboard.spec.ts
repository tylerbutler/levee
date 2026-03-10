import { expect, test } from "../fixtures/admin-fixtures.ts";

test.describe("admin dashboard", () => {
	test("welcome card and dashboard content visible after login", async ({
		authenticatedPage: page,
	}) => {
		await expect(page.locator(".page.dashboard")).toBeVisible();
		await expect(page.locator(".welcome-card")).toBeVisible();
	});

	test("user display name shown in nav bar", async ({
		authenticatedPage: page,
		testUser,
	}) => {
		await expect(page.locator(".nav")).toBeVisible();
		await expect(page.locator(".nav-brand h1")).toContainText("Levee Admin");
		await expect(page.locator(".nav-user p")).toContainText(
			testUser.displayName,
		);
	});

	test("dashboard sections render", async ({ authenticatedPage: page }) => {
		await expect(page.locator(".tenants-card")).toBeVisible();
		await expect(page.locator(".quick-actions-card")).toBeVisible();
	});

	test("unauthenticated access to dashboard redirects to login", async ({
		page,
	}) => {
		await page.goto("/admin/dashboard");

		// Should end up on the login page since we're not authenticated
		await expect(page.locator(".auth-page.login-page")).toBeVisible({
			timeout: 10_000,
		});
	});
});
