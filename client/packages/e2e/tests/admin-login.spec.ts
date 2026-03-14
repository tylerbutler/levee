import { expect, test } from "../fixtures/admin-fixtures.ts";

test.describe("admin login page", () => {
	test("login form renders with all fields and register link", async ({
		page,
	}) => {
		await page.goto("/admin/login");

		await expect(page.locator(".auth-page.login-page")).toBeVisible();
		await expect(page.locator(".auth-card")).toBeVisible();
		await expect(page.locator(".auth-title")).toBeVisible();
		await expect(page.locator("#email")).toBeVisible();
		await expect(page.locator("#password")).toBeVisible();
		await expect(page.locator('button[type="submit"]')).toBeVisible();
		await expect(page.locator('a[href="/admin/register"]')).toBeVisible();
	});

	test("navigate to register page via footer link", async ({ page }) => {
		await page.goto("/admin/login");

		await page.locator('a[href="/admin/register"]').click();
		await expect(page.locator(".auth-page.register-page")).toBeVisible();
	});

	test("error shown for invalid credentials", async ({ page }) => {
		await page.goto("/admin/login");

		await page.locator("#email").fill("nonexistent@test.example.com");
		await page.locator("#password").fill("wrongpassword123");
		await page.locator('button[type="submit"]').click();

		await expect(page.locator(".alert-error")).toBeVisible();
		await expect(page.locator(".alert-message")).toBeVisible();
	});

	test("successful login redirects to dashboard", async ({
		page,
		testUser,
	}) => {
		// Register via API first
		const response = await fetch("http://localhost:4000/api/auth/register", {
			method: "POST",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify({
				email: testUser.email,
				password: testUser.password,
				display_name: testUser.displayName,
			}),
		});
		expect(response.ok).toBe(true);

		// Login via UI
		await page.goto("/admin/login");
		await page.locator("#email").fill(testUser.email);
		await page.locator("#password").fill(testUser.password);
		await page.locator('button[type="submit"]').click();

		await expect(page.locator(".authenticated-layout")).toBeVisible({
			timeout: 10_000,
		});
		await expect(page.locator(".page.dashboard")).toBeVisible();
	});
});
