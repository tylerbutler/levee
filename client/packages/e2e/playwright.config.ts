import { defineConfig, devices } from "@playwright/test";

export default defineConfig({
	testDir: ".",
	testMatch: "*.spec.ts",
	timeout: 30_000,
	expect: {
		timeout: 10_000,
	},
	fullyParallel: false,
	forbidOnly: !!process.env.CI,
	retries: process.env.CI ? 2 : 0,
	workers: 1,
	reporter: process.env.CI ? "github" : "list",

	globalSetup: "./global-setup.ts",

	use: {
		baseURL: "http://localhost:4000",
		trace: "on-first-retry",
		video: "on-first-retry",
	},

	projects: [
		{
			name: "chromium",
			use: { ...devices["Desktop Chrome"] },
		},
	],
});
