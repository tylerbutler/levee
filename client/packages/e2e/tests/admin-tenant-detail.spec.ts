import { expect, test } from "../fixtures/admin-fixtures.ts";

test.describe("admin tenant detail page", () => {
	// Helper: create a tenant via the UI and return the page on the detail view
	async function createTenantViaUi(
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
	}

	test("tenant detail page shows tenant information section", async ({
		authenticatedPage: page,
	}) => {
		const tenantName = `Detail Test ${Date.now()}`;
		await createTenantViaUi(page, tenantName);

		// Verify tenant information card
		await expect(page.locator(".tenant-detail-content")).toBeVisible();
		await expect(page.locator(".detail-label")).first().toBeVisible();
		await expect(page.locator(".detail-value")).first().toBeVisible();
	});

	test("tenant detail page shows connection URLs section", async ({
		authenticatedPage: page,
	}) => {
		const tenantName = `URLs Test ${Date.now()}`;
		await createTenantViaUi(page, tenantName);

		// Verify connection URLs are displayed
		await expect(page.getByText("Connection URLs")).toBeVisible();
		await expect(page.getByText("HTTP URL")).toBeVisible();
		await expect(page.getByText("WebSocket URL")).toBeVisible();
		await expect(page.getByText("Token Mint")).toBeVisible();
		await expect(page.getByText("Client Config")).toBeVisible();

		// Verify code block with client config snippet exists
		await expect(page.locator(".code-block")).toBeVisible();
	});

	test("tenant detail page shows secret sections with toggle buttons", async ({
		authenticatedPage: page,
	}) => {
		const tenantName = `Secrets Test ${Date.now()}`;
		await createTenantViaUi(page, tenantName);

		// Verify both secret sections exist
		await expect(page.getByText("Secret 1")).toBeVisible();
		await expect(page.getByText("Secret 2")).toBeVisible();

		// Verify secret display and toggle buttons
		const secretDisplays = page.locator(".secret-display");
		await expect(secretDisplays).toHaveCount(2);

		// Secrets should initially show masked values
		const secretValues = page.locator(".secret-value");
		await expect(secretValues.first()).toBeVisible();
	});

	test("tenant detail page has back link to tenants list", async ({
		authenticatedPage: page,
	}) => {
		const tenantName = `Back Link Test ${Date.now()}`;
		await createTenantViaUi(page, tenantName);

		const backLink = page.locator('a.back-link[href="/admin/tenants"]');
		await expect(backLink).toBeVisible();
		await expect(backLink).toContainText("Back to Tenants");
	});

	test("tenant detail page shows danger zone with delete button", async ({
		authenticatedPage: page,
	}) => {
		const tenantName = `Danger Zone Test ${Date.now()}`;
		await createTenantViaUi(page, tenantName);

		// Verify danger zone
		await expect(page.locator(".danger-card")).toBeVisible();
		await expect(page.getByText("Danger Zone")).toBeVisible();
		await expect(
			page.locator(".danger-card .btn.btn-danger"),
		).toBeVisible();
	});

	test("tenant detail page has view documents link", async ({
		authenticatedPage: page,
	}) => {
		const tenantName = `Docs Link Test ${Date.now()}`;
		await createTenantViaUi(page, tenantName);

		const docsLink = page.locator(
			'a.btn.btn-secondary[href*="/documents"]',
		);
		await expect(docsLink).toBeVisible();
		await expect(docsLink).toContainText("View Documents");
	});
});
