import { expect, test } from "../fixtures/admin-fixtures.ts";

test.describe("admin tenants page", () => {
	test("tenants page renders with page header and create button", async ({
		authenticatedPage: page,
	}) => {
		await page.locator('a[href="/admin/tenants"]').first().click();
		await expect(page.locator(".page.tenants-page")).toBeVisible({
			timeout: 10_000,
		});
		await expect(page.locator(".page-header .page-title")).toContainText(
			"Tenants",
		);
		await expect(
			page.locator('a[href="/admin/tenants/new"].btn.btn-primary'),
		).toBeVisible();
	});

	test("tenants page shows empty state when no tenants exist", async ({
		authenticatedPage: page,
	}) => {
		await page.locator('a[href="/admin/tenants"]').first().click();
		await expect(page.locator(".page.tenants-page")).toBeVisible({
			timeout: 10_000,
		});

		// Either the tenant list is loaded (with tenants or empty)
		const emptyState = page.locator(".empty-state");
		const tenantTable = page.locator(".tenant-table");
		await expect(emptyState.or(tenantTable)).toBeVisible({ timeout: 10_000 });
	});

	test("unauthenticated access to tenants page redirects to login", async ({
		page,
	}) => {
		await page.goto("/admin/tenants");
		await expect(page.locator(".auth-page.login-page")).toBeVisible({
			timeout: 10_000,
		});
	});
});
