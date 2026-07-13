import { fileURLToPath } from "node:url";
import { defineConfig, mergeConfig } from "vitest/config";

import defaultConfig from "../../vitest.config";

// biome-ignore lint/style/noDefaultExport: correct pattern for config files
export default mergeConfig(
	defaultConfig,
	defineConfig({
		resolve: {
			alias: {
				"$app/paths": fileURLToPath(
					new URL("./test/mocks/app-paths.ts", import.meta.url),
				),
			},
		},
	}),
);
