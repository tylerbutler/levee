import { expect, test } from "../fixtures/admin-fixtures.ts";

test.describe("admin create tenant page", () => {
	test("create tenant form renders with all fields", async ({
		authenticatedPage: page,
	}) => {
		await page.goto("/admin/tenants/new");
		await expect(page.locator(".page.tenant-new-page")).toBeVisible({
			timeout: 10_000,
		});
		await expect(page.locator(".page-title")).toContainText("Create Tenant");
		await expect(page.locator("#name")).toBeVisible();
		await expect(
			page.locator('button[type="submit"].btn.btn-primary'),
		).toBeVisible();
	});

	test("create tenant form has back link to tenants list", async ({
		authenticatedPage: page,
	}) => {
		await page.goto("/admin/tenants/new");
		await expect(page.locator(".page.tenant-new-page")).toBeVisible({
			timeout: 10_000,
		});

		const backLink = page.locator('a.back-link[href="/admin/tenants"]');
		await expect(backLink).toBeVisible();
		await expect(backLink).toContainText("Back to Tenants");
	});

	test("create tenant form shows error for empty name", async ({
		authenticatedPage: page,
	}) => {
		await page.goto("/admin/tenants/new");
		await expect(page.locator(".page.tenant-new-page")).toBeVisible({
			timeout: 10_000,
		});

		// Submit with empty name
		await page.locator('button[type="submit"]').click();
		await expect(page.locator(".alert-error")).toBeVisible();
		await expect(page.locator(".alert-message")).toContainText(
			"Name is required",
		);
	});

	test("create tenant successfully and redirect to tenant detail", async ({
		authenticatedPage: page,
	}) => {
		const tenantName = `Test Tenant ${Date.now()}`;

		await page.goto("/admin/tenants/new");
		await expect(page.locator(".page.tenant-new-page")).toBeVisible({
			timeout: 10_000,
		});

		await page.locator("#name").fill(tenantName);
		await page.locator('button[type="submit"]').click();

		// Should redirect to tenant detail page
		await expect(page.locator(".page.tenant-detail-page")).toBeVisible({
			timeout: 15_000,
		});
		await expect(page.locator(".page-title")).toContainText(tenantName);
	});

	test("unauthenticated access to create tenant page redirects to login", async ({
		page,
	}) => {
		await page.goto("/admin/tenants/new");
		await expect(page.locator(".auth-page.login-page")).toBeVisible({
			timeout: 10_000,
		});
	});
});
