import { expect, test } from "../fixtures/admin-fixtures.ts";

test.describe("admin dashboard quick actions and navigation", () => {
	test("quick actions card has create tenant link", async ({
		authenticatedPage: page,
	}) => {
		const quickActions = page.locator(".quick-actions-card");
		await expect(quickActions).toBeVisible();

		const createLink = quickActions.locator('a[href="/admin/tenants/new"]');
		await expect(createLink).toBeVisible();
		await expect(createLink).toContainText("Create New Tenant");
	});

	test("quick actions card has view all tenants link", async ({
		authenticatedPage: page,
	}) => {
		const quickActions = page.locator(".quick-actions-card");
		await expect(quickActions).toBeVisible();

		const viewAllLink = quickActions.locator('a[href="/admin/tenants"]');
		await expect(viewAllLink).toBeVisible();
		await expect(viewAllLink).toContainText("View All Tenants");
	});

	test("clicking create tenant quick action navigates to form", async ({
		authenticatedPage: page,
	}) => {
		const quickActions = page.locator(".quick-actions-card");
		await quickActions.locator('a[href="/admin/tenants/new"]').click();

		await expect(page.locator(".page.tenant-new-page")).toBeVisible({
			timeout: 10_000,
		});
		await expect(page.locator(".page-title")).toContainText("Create Tenant");
	});

	test("clicking view all tenants quick action navigates to list", async ({
		authenticatedPage: page,
	}) => {
		const quickActions = page.locator(".quick-actions-card");
		await quickActions.locator('a[href="/admin/tenants"]').click();

		await expect(page.locator(".page.tenants-page")).toBeVisible({
			timeout: 10_000,
		});
		await expect(page.locator(".page-title")).toContainText("Tenants");
	});

	test("tenants card on dashboard links to create first tenant when empty", async ({
		authenticatedPage: page,
	}) => {
		const tenantsCard = page.locator(".tenants-card");
		await expect(tenantsCard).toBeVisible();

		// Either shows empty state with create link, or shows tenant list
		const emptyCreate = tenantsCard.locator('a[href="/admin/tenants/new"]');
		const tenantList = tenantsCard.locator(".tenant-list");
		await expect(emptyCreate.or(tenantList)).toBeVisible({ timeout: 10_000 });
	});

	test("tenants card shows tenant count and list when tenants exist", async ({
		authenticatedPage: page,
	}) => {
		// First create a tenant
		await page.goto("/admin/tenants/new");
		await expect(page.locator(".page.tenant-new-page")).toBeVisible({
			timeout: 10_000,
		});
		await page.locator("#name").fill(`Dashboard Tenant ${Date.now()}`);
		await page.locator('button[type="submit"]').click();
		await expect(page.locator(".page.tenant-detail-page")).toBeVisible({
			timeout: 15_000,
		});

		// Go back to dashboard
		await page.goto("/admin/dashboard");
		await expect(page.locator(".page.dashboard")).toBeVisible({
			timeout: 10_000,
		});

		// Tenants card should show tenant count and list
		const tenantsCard = page.locator(".tenants-card");
		await expect(tenantsCard).toBeVisible();
		await expect(tenantsCard.locator(".tenant-count")).toBeVisible({
			timeout: 10_000,
		});
		await expect(tenantsCard.locator(".tenant-list")).toBeVisible();
	});
});
