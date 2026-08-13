import { existsSync, readdirSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

const clientRoot = fileURLToPath(new URL("../", import.meta.url));
const repositoryRoot = fileURLToPath(new URL("../../", import.meta.url));

const workspacePackageJson = JSON.parse(
	readFileSync(`${clientRoot}/package.json`, "utf8"),
) as {
	scripts?: Record<string, string>;
};
const changieConfig = readFileSync(`${clientRoot}/.changie.yaml`, "utf8");
const changieProjects = Array.from(
	changieConfig.matchAll(/^\s+key:\s*(\S+)\s*$/gm),
	(match) => match[1],
);

const publicPackageProjects = readdirSync(`${clientRoot}/packages`, {
	withFileTypes: true,
})
	.filter((entry) => entry.isDirectory())
	.flatMap((entry) => {
		const packageJsonPath = `${clientRoot}/packages/${entry.name}/package.json`;
		if (!existsSync(packageJsonPath)) {
			return [];
		}

		const packageJson = JSON.parse(readFileSync(packageJsonPath, "utf8")) as {
			name?: string;
			private?: boolean;
		};

		if (packageJson.private || !packageJson.name?.startsWith("@tylerbu/")) {
			return [];
		}

		return [packageJson.name.slice("@tylerbu/".length)];
	});

const workflowProjectInputs = [
	".github/workflows/ci.yml",
	".github/workflows/client-changie-release.yml",
	".github/workflows/auto-tag.yml",
];

function sorted(values: string[]): string[] {
	return [...values].sort();
}

describe("client release configuration", () => {
	it("leaves Floodgate release ownership in its repository", () => {
		expect(changieProjects).not.toContain("floodgate-client");
		expect(
			existsSync(`${clientRoot}/packages/floodgate-client/package.json`),
		).toBe(false);
		expect(workspacePackageJson.scripts?.["ci:publish"]).toContain(
			"pnpm publish -r",
		);
	});

	it("registers every public client package with Changie", () => {
		expect(sorted(changieProjects)).toEqual(sorted(publicPackageProjects));

		for (const project of publicPackageProjects) {
			expect(changieConfig).toContain(
				`changelog: packages/${project}/CHANGELOG.md`,
			);
			expect(changieConfig).toContain(`path: packages/${project}/package.json`);
		}
	});

	it("keeps explicit workflow project inputs aligned with Changie", () => {
		for (const workflowPath of workflowProjectInputs) {
			const workflow = readFileSync(
				`${repositoryRoot}/${workflowPath}`,
				"utf8",
			);
			const projects = workflow.match(/^\s+projects:\s*([^\n#]+)\s*$/m)?.[1];

			expect(
				projects,
				`${workflowPath} must declare a projects input`,
			).toBeDefined();
			expect(
				sorted(projects?.split(",").map((project) => project.trim()) ?? []),
			).toEqual(sorted(changieProjects));
		}
	});

	it("routes every unreleased fragment to a registered project", () => {
		const unreleasedPath = `${clientRoot}/.changes/unreleased`;
		const fragments = existsSync(unreleasedPath)
			? readdirSync(unreleasedPath).filter((file) => file.endsWith(".yaml"))
			: [];

		for (const fragment of fragments) {
			const contents = readFileSync(`${unreleasedPath}/${fragment}`, "utf8");
			const project = contents.match(/^project:\s*(\S+)\s*$/m)?.[1];

			expect(project, `${fragment} must declare a project`).toBeDefined();
			expect(
				changieProjects,
				`${fragment} targets an unknown project`,
			).toContain(project);
		}
	});
});
