import { expect, test } from "../fixtures/admin-fixtures.ts";

test.describe("admin documents page", () => {
	// Helper: create a tenant and navigate to its document list
	async function createTenantAndGoToDocuments(
		page: import("@playwright/test").Page,
		name: string,
	) {
		await page.goto("/admin/tenants/new");
		await expect(page.locator(".page.tenant-new-page")).toBeVisible({
			timeout: 10_000,
		});
		await page.locator("#name").fill(name);
		await page.locator('button[type="submit"]').click();
		await expect(page.locator(".page.tenant-detail-page")).toBeVisible({
			timeout: 15_000,
		});

		// Click "View Documents" link
		await page.locator('a.btn.btn-secondary[href*="/documents"]').click();
		await expect(page.locator(".page.document-list-page")).toBeVisible({
			timeout: 10_000,
		});
	}

	test("document list page renders with header", async ({
		authenticatedPage: page,
	}) => {
		const tenantName = `Doc List Test ${Date.now()}`;
		await createTenantAndGoToDocuments(page, tenantName);

		await expect(page.locator(".page-title")).toContainText("Documents");
	});

	test("document list page shows empty state for new tenant", async ({
		authenticatedPage: page,
	}) => {
		const tenantName = `Empty Docs Test ${Date.now()}`;
		await createTenantAndGoToDocuments(page, tenantName);

		// New tenant should have no documents
		await expect(page.locator(".empty-state")).toBeVisible({ timeout: 10_000 });
		await expect(page.getByText("No documents in this tenant.")).toBeVisible();
	});

	test("document list page has back link to tenant detail", async ({
		authenticatedPage: page,
	}) => {
		const tenantName = `Back Link Docs Test ${Date.now()}`;
		await createTenantAndGoToDocuments(page, tenantName);

		const backLink = page.locator("a.back-link");
		await expect(backLink).toBeVisible();
		await expect(backLink).toContainText("Back to Tenant");
	});

	test("clicking back link returns to tenant detail", async ({
		authenticatedPage: page,
	}) => {
		const tenantName = `Nav Back Test ${Date.now()}`;
		await createTenantAndGoToDocuments(page, tenantName);

		await page.locator("a.back-link").click();
		await expect(page.locator(".page.tenant-detail-page")).toBeVisible({
			timeout: 10_000,
		});
		await expect(page.locator(".page-title")).toContainText(tenantName);
	});
});
