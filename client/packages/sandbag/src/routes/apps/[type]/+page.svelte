<script lang="ts">
import { onDestroy, onMount } from "svelte";
import { page } from "$app/state";
import { parseConfigFromParams } from "$lib/config";
import { loadApp } from "$lib/registry";

let container: HTMLDivElement;
let unmount: (() => void) | undefined;
let error = $state<string | undefined>();
let loading = $state(true);

const appType = $derived(page.params.type);

onMount(async () => {
	const config = parseConfigFromParams(new URLSearchParams(page.url.search));
	try {
		const app = await loadApp(appType);
		if (!app) {
			error = `Unknown app type: ${appType}`;
			loading = false;
			return;
		}
		const result = await app.mount(container, config);
		unmount = result.unmount;
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
