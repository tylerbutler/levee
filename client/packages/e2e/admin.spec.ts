import { expect, test } from "@playwright/test";
import { registerUser } from "./support/auth-helpers.ts";

test.describe("admin login page", () => {
	test("renders login page with sign-in form", async ({ page }) => {
		await page.goto("/admin");

		await expect(page.locator(".login-page")).toBeVisible();
		await expect(page.locator("h1.auth-title")).toHaveText("Sign In");

		// Form fields
		await expect(page.locator("#email")).toBeVisible();
		await expect(page.locator("#password")).toBeVisible();
		await expect(page.locator("button.btn-primary")).toHaveText("Sign In");
	});

	test("has GitHub sign-in button", async ({ page }) => {
		await page.goto("/admin");

		await expect(page.locator("button.btn-github")).toHaveText(
			"Sign in with GitHub",
		);
	});

	test("register link navigates to register page", async ({ page }) => {
		await page.goto("/admin");

		await page.click("a[href='/admin/register']");
		await expect(page.locator(".register-page")).toBeVisible();
	});
});

test.describe("admin register page", () => {
	test("renders register page via direct URL", async ({ page }) => {
		await page.goto("/admin/register");

		await expect(page.locator(".register-page")).toBeVisible();
		await expect(page.locator("h1.auth-title")).toHaveText("Create Account");

		// All form fields
		await expect(page.locator("#display_name")).toBeVisible();
		await expect(page.locator("#email")).toBeVisible();
		await expect(page.locator("#password")).toBeVisible();
		await expect(page.locator("#confirm_password")).toBeVisible();
		await expect(page.locator("button.btn-primary")).toHaveText(
			"Create Account",
		);
	});

	test("sign-in link navigates back to login page", async ({ page }) => {
		await page.goto("/admin/register");
		await expect(page.locator(".register-page")).toBeVisible();

		await page.click("a[href='/admin/login']");
		await expect(page.locator(".login-page")).toBeVisible();
	});
});

test.describe("admin dashboard", () => {
	test("renders dashboard after token auth", async ({ page }) => {
		const { token } = await registerUser("Dashboard Tester");

		await page.goto(`/admin/dashboard?token=${token}`);

		await expect(page.locator("h1.page-title")).toHaveText("Dashboard");
	});

	test("nav bar shows brand and user name", async ({ page }) => {
		const { token } = await registerUser("Nav User");

		await page.goto(`/admin/dashboard?token=${token}`);
		await expect(page.locator("h1.page-title")).toHaveText("Dashboard");

		await expect(page.locator(".nav-brand h1")).toHaveText("Levee Admin");
		await expect(page.locator(".nav-user p")).toHaveText("Nav User");
	});

	test("dashboard sections render", async ({ page }) => {
		const { token } = await registerUser("Sections Tester");

		await page.goto(`/admin/dashboard?token=${token}`);
		await expect(page.locator("h1.page-title")).toHaveText("Dashboard");

		await expect(page.locator(".welcome-card")).toBeVisible();
		await expect(page.locator(".tenants-card")).toBeVisible();
		await expect(page.locator(".quick-actions-card")).toBeVisible();
	});

	test("logout returns to login page", async ({ page }) => {
		const { token } = await registerUser("Logout Tester");

		await page.goto(`/admin/dashboard?token=${token}`);
		await expect(page.locator("h1.page-title")).toHaveText("Dashboard");

		await page.locator(".nav-user button").click();

		await expect(page.locator(".login-page")).toBeVisible();
		await expect(page.locator("h1.auth-title")).toHaveText("Sign In");
	});
});

test.describe("admin navigation guards", () => {
	test("dashboard redirects to login when unauthenticated", async ({
		page,
	}) => {
		await page.goto("/admin/dashboard");
		await expect(page.locator(".login-page")).toBeVisible();
	});

	test("tenants page redirects to login when unauthenticated", async ({
		page,
	}) => {
		await page.goto("/admin/tenants");
		await expect(page.locator(".login-page")).toBeVisible();
	});
});

test.describe("admin 404 page", () => {
	test("unknown route shows 404", async ({ page }) => {
		await page.goto("/admin/nonexistent");

		await expect(page.locator(".not-found")).toBeVisible();
		await expect(page.locator(".not-found h1")).toHaveText("404 - Not Found");
	});
});
