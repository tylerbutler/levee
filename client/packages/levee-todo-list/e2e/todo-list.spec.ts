import {
	expect,
	getContainerIdFromUrl,
	test,
	waitForConnected,
	waitForTodoView,
} from "./fixtures/test-fixtures.ts";

test.describe("single user", () => {
	test("app loads and shows todo list with initial items", async ({
		connectedPage: page,
	}) => {
		// Verify the todo view is rendered
		await expect(page.locator(".todo-view")).toBeVisible();

		// Should show the default list title
		const titleInput = page.locator(".todo-title");
		await expect(titleInput).toBeVisible();
		await expect(titleInput).toHaveValue("My to-do list");

		// Should show the two initial todo items
		const items = page.locator(".item-wrap");
		await expect(items).toHaveCount(2);

		// First item: "Buy groceries" (unchecked)
		const firstItemInput = items.nth(0).locator(".todo-item-input");
		await expect(firstItemInput).toHaveValue("Buy groceries");
		const firstCheckbox = items.nth(0).locator(".todo-item-checkbox");
		await expect(firstCheckbox).not.toBeChecked();

		// Second item: "Walk the dog" (checked)
		const secondItemInput = items.nth(1).locator(".todo-item-input");
		await expect(secondItemInput).toHaveValue("Walk the dog");
		const secondCheckbox = items.nth(1).locator(".todo-item-checkbox");
		await expect(secondCheckbox).toBeChecked();
	});

	test("add new todo item", async ({ connectedPage: page }) => {
		// Type into the new item input
		const newItemInput = page.locator(".new-item-text");
		await newItemInput.fill("Learn Fluid Framework");

		// Click the add button
		await page.locator(".new-item-button").click();

		// Should now have 3 items
		const items = page.locator(".item-wrap");
		await expect(items).toHaveCount(3);

		// The new item should be at the end
		const newItemText = items.nth(2).locator(".todo-item-input");
		await expect(newItemText).toHaveValue("Learn Fluid Framework");

		// New item should be unchecked
		const newCheckbox = items.nth(2).locator(".todo-item-checkbox");
		await expect(newCheckbox).not.toBeChecked();
	});

	test("toggle todo item completed", async ({ connectedPage: page }) => {
		// First item starts unchecked
		const firstCheckbox = page
			.locator(".item-wrap")
			.nth(0)
			.locator(".todo-item-checkbox");
		await expect(firstCheckbox).not.toBeChecked();

		// Check it
		await firstCheckbox.check();
		await expect(firstCheckbox).toBeChecked();

		// Uncheck it
		await firstCheckbox.uncheck();
		await expect(firstCheckbox).not.toBeChecked();
	});

	test("delete todo item", async ({ connectedPage: page }) => {
		// Start with 2 items
		const items = page.locator(".item-wrap");
		await expect(items).toHaveCount(2);

		// Click the X button on the first item
		await items.nth(0).locator(".action-button").click();

		// Should now have 1 item
		await expect(items).toHaveCount(1);

		// The remaining item should be "Walk the dog"
		const remainingItemInput = items.nth(0).locator(".todo-item-input");
		await expect(remainingItemInput).toHaveValue("Walk the dog");
	});

	test("expand and collapse todo item details", async ({
		connectedPage: page,
	}) => {
		// Details should be hidden initially
		const details = page.locator(".todo-item-details");
		await expect(details).toHaveCount(0);

		// Click the expand button on the first item
		const expandButton = page
			.locator(".item-wrap")
			.nth(0)
			.locator(".todo-item-expand-button");
		await expandButton.click();

		// Details textarea should now be visible
		await expect(details).toHaveCount(1);
		await expect(details.first()).toBeVisible();

		// Click again to collapse
		await expandButton.click();
		await expect(details).toHaveCount(0);
	});
});

test.describe("multi-user collaboration", () => {
	test("second user sees same todo items", async ({
		connectedPage: page1,
		secondUser: { page: page2 },
	}) => {
		// Both pages should be connected
		await expect(page1.locator("#status")).toHaveClass("connected");
		await expect(page2.locator("#status")).toHaveClass("connected");

		// Both should have the same container ID
		const containerId1 = getContainerIdFromUrl(page1);
		const containerId2 = getContainerIdFromUrl(page2);
		expect(containerId1).toBe(containerId2);

		// Page2 should see the same initial items
		const items2 = page2.locator(".item-wrap");
		await expect(items2).toHaveCount(2);

		const firstItemInput2 = items2.nth(0).locator(".todo-item-input");
		await expect(firstItemInput2).toHaveValue("Buy groceries");

		const secondItemInput2 = items2.nth(1).locator(".todo-item-input");
		await expect(secondItemInput2).toHaveValue("Walk the dog");
	});

	test("adding item on one side appears on the other", async ({
		connectedPage: page1,
		secondUser: { page: page2 },
	}) => {
		// Add a new item on page1
		const newItemInput = page1.locator(".new-item-text");
		await newItemInput.fill("Shared task");
		await page1.locator(".new-item-button").click();

		// Page1 should show 3 items
		await expect(page1.locator(".item-wrap")).toHaveCount(3);

		// Page2 should also show 3 items after sync
		await expect(page2.locator(".item-wrap")).toHaveCount(3, {
			timeout: 10_000,
		});

		// The new item should appear on page2
		const newItem2 = page2
			.locator(".item-wrap")
			.nth(2)
			.locator(".todo-item-input");
		await expect(newItem2).toHaveValue("Shared task");
	});

	test("checking item syncs across users", async ({
		connectedPage: page1,
		secondUser: { page: page2 },
	}) => {
		// First item is unchecked on both pages
		const checkbox1 = page1
			.locator(".item-wrap")
			.nth(0)
			.locator(".todo-item-checkbox");
		const checkbox2 = page2
			.locator(".item-wrap")
			.nth(0)
			.locator(".todo-item-checkbox");

		await expect(checkbox1).not.toBeChecked();
		await expect(checkbox2).not.toBeChecked();

		// Check on page1
		await checkbox1.check();

		// Should sync to page2
		await expect(checkbox2).toBeChecked({ timeout: 10_000 });

		// Uncheck on page2
		await checkbox2.uncheck();

		// Should sync back to page1
		await expect(checkbox1).not.toBeChecked({ timeout: 10_000 });
	});

	test("deleting item syncs across users", async ({
		connectedPage: page1,
		secondUser: { page: page2 },
	}) => {
		// Both start with 2 items
		await expect(page1.locator(".item-wrap")).toHaveCount(2);
		await expect(page2.locator(".item-wrap")).toHaveCount(2);

		// Delete first item on page1
		await page1.locator(".item-wrap").nth(0).locator(".action-button").click();

		// Page1 should have 1 item
		await expect(page1.locator(".item-wrap")).toHaveCount(1);

		// Page2 should also have 1 item after sync
		await expect(page2.locator(".item-wrap")).toHaveCount(1, {
			timeout: 10_000,
		});

		// The remaining item should be "Walk the dog" on both
		const remaining1 = page1
			.locator(".item-wrap")
			.nth(0)
			.locator(".todo-item-input");
		const remaining2 = page2
			.locator(".item-wrap")
			.nth(0)
			.locator(".todo-item-input");

		await expect(remaining1).toHaveValue("Walk the dog");
		await expect(remaining2).toHaveValue("Walk the dog");
	});
});
