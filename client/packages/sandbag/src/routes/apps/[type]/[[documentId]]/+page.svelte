<script lang="ts">
import { onDestroy, onMount } from "svelte";
import { goto } from "$app/navigation";
import { base } from "$app/paths";
import { page } from "$app/state";
import { getAuthToken } from "$lib/auth.svelte";
import { parseConfigFromParams } from "$lib/config";
import { loadApp } from "$lib/registry";

const appType = $derived(page.params.type);
const documentId = $derived(page.params.documentId);

let container: HTMLDivElement;
let unmount: (() => void) | undefined;
let error = $state<string | undefined>();
let loading = $state(true);

onMount(async () => {
	const params = new URLSearchParams(page.url.search);
	const baseConfig = parseConfigFromParams(params);
	const authToken = params.get("authToken") ?? getAuthToken();

	try {
		const app = await loadApp(appType!);
		if (!app) {
			error = `Unknown app type: ${appType}`;
			loading = false;
			return;
		}

		const config = {
			...baseConfig,
			authToken: authToken ?? undefined,
			documentId: documentId ?? undefined,
			appName: app.packageName,
			appVersion: app.packageVersion,
		};

		const result = await app.mount(container, config);
		unmount = result.unmount;

		// After creating a new document, put the documentId in the URL
		if (result.documentId && result.documentId !== documentId) {
			await goto(`${base}/apps/${appType}/${result.documentId}`, {
				replaceState: true,
			});
		}
	} catch (err) {
		error = err instanceof Error ? err.message : String(err);
	}
	loading = false;
});

onDestroy(() => unmount?.());
</script>

{#if error}
	<div class="error">
		<p>Failed to load app: {error}</p>
	</div>
{/if}

{#if loading}
	<div class="loading">Loading {appType}…</div>
{/if}

<div bind:this={container} class="app-root" class:hidden={loading || !!error}></div>

<style>
	.app-root {
		width: 100%;
		min-height: 100vh;
	}

	.hidden {
		display: none;
	}

	.loading, .error {
		display: flex;
		align-items: center;
		justify-content: center;
		min-height: 100vh;
		font-size: 1rem;
		color: #64748b;
	}

	.error {
		color: #dc2626;
	}
</style>
