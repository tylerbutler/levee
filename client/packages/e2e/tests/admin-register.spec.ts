import { expect, test } from "../fixtures/admin-fixtures.ts";

test.describe("admin register page", () => {
	test("registration form renders with all fields and login link", async ({
		page,
	}) => {
		await page.goto("/admin/register");

		await expect(page.locator(".auth-page.register-page")).toBeVisible();
		await expect(page.locator(".auth-card")).toBeVisible();
		await expect(page.locator(".auth-title")).toBeVisible();
		await expect(page.locator("#display_name")).toBeVisible();
		await expect(page.locator("#email")).toBeVisible();
		await expect(page.locator("#password")).toBeVisible();
		await expect(page.locator("#confirm_password")).toBeVisible();
		await expect(page.locator('button[type="submit"]')).toBeVisible();
		await expect(page.locator('a[href="/admin/login"]')).toBeVisible();
	});

	test("navigate to login page via footer link", async ({ page }) => {
		await page.goto("/admin/register");

		await page.locator('a[href="/admin/login"]').click();
		await expect(page.locator(".auth-page.login-page")).toBeVisible();
	});

	test("successful registration redirects to dashboard", async ({
		page,
		testUser,
	}) => {
		await page.goto("/admin/register");

		await page.locator("#display_name").fill(testUser.displayName);
		await page.locator("#email").fill(testUser.email);
		await page.locator("#password").fill(testUser.password);
		await page.locator("#confirm_password").fill(testUser.password);
		await page.locator('button[type="submit"]').click();

		await expect(page.locator(".authenticated-layout")).toBeVisible({
			timeout: 10_000,
		});
		await expect(page.locator(".page.dashboard")).toBeVisible();
	});

	test("password mismatch shows client-side error", async ({
		page,
		testUser,
	}) => {
		await page.goto("/admin/register");

		await page.locator("#display_name").fill(testUser.displayName);
		await page.locator("#email").fill(testUser.email);
		await page.locator("#password").fill(testUser.password);
		await page.locator("#confirm_password").fill("differentpassword");
		await page.locator('button[type="submit"]').click();

		await expect(page.locator(".alert-error")).toBeVisible();
		await expect(page.locator(".alert-message")).toBeVisible();
	});
});
