import { expect, test } from "../fixtures/admin-fixtures.ts";

test.describe("admin navigation", () => {
	test("logout returns to login page", async ({ authenticatedPage: page }) => {
		// Click logout button in nav
		await page.locator(".nav-user button").click();

		await expect(page.locator(".auth-page.login-page")).toBeVisible({
			timeout: 10_000,
		});
	});

	test("not-found page renders for unknown routes", async ({ page }) => {
		await page.goto("/admin/nonexistent-page");

		// Should show not-found or redirect to login (depends on auth state)
		const notFound = page.locator(".not-found");
		const loginPage = page.locator(".auth-page.login-page");
		await expect(notFound.or(loginPage)).toBeVisible({ timeout: 10_000 });
	});

	test("not-found page links back to login when unauthenticated", async ({
		page,
	}) => {
		await page.goto("/admin/nonexistent-page");

		// When unauthenticated, should redirect to login
		await expect(page.locator(".auth-page.login-page")).toBeVisible({
			timeout: 10_000,
		});
	});

	test("after logout, protected routes redirect to login", async ({
		authenticatedPage: page,
	}) => {
		// Log out
		await page.locator(".nav-user button").click();
		await expect(page.locator(".auth-page.login-page")).toBeVisible({
			timeout: 10_000,
		});

		// Try navigating to dashboard
		await page.goto("/admin/dashboard");
		await expect(page.locator(".auth-page.login-page")).toBeVisible({
			timeout: 10_000,
		});
	});
});
