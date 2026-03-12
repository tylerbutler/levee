<script lang="ts">
import { base } from "$app/paths";
import { page } from "$app/state";
import { buildAppUrl, getSandbag } from "$lib/api";
import { getAuthToken } from "$lib/auth.svelte";
import { loadApp } from "$lib/registry";
import type { SandbagApp } from "$lib/types";

const sandbagId = $derived(page.params.id);
const sandbag = $derived(getSandbag(sandbagId));
const authToken = $derived(getAuthToken());
const iframeSrc = $derived(
	sandbag
		? buildAppUrl(
				sandbag.appType,
				sandbag.documentId || undefined,
				authToken ?? undefined,
			)
		: "",
);

let appInfo = $state<SandbagApp | undefined>();

$effect(() => {
	if (sandbag) {
		loadApp(sandbag.appType).then((info) => {
			appInfo = info;
		});
	}
});
</script>

<div class="sandbag-view">
	{#if sandbag && appInfo}
		<div class="view-header">
			<a href="{base}/" class="back-link">← Dashboard</a>
			<span class="header-icon">{appInfo.icon}</span>
			<h1>{sandbag.name}</h1>
			<span class="header-type">{appInfo.label}</span>
			<div class="view-actions">
				<button
					class="btn-outline"
					onclick={() => navigator.clipboard.writeText(window.location.href)}
				>
					📋 Copy Link
				</button>
				<button
					class="btn-outline"
					onclick={() => window.open(window.location.href, "_blank")}
				>
					↗ New Tab
				</button>
			</div>
		</div>

		<div class="iframe-container">
			<iframe
				src={iframeSrc}
				title="{appInfo.label}: {sandbag.name}"
				sandbox="allow-scripts allow-same-origin allow-popups allow-forms"
			></iframe>
		</div>
	{:else}
		<div class="not-found">
			<h2>Sandbag not found</h2>
			<p>The sandbag "{sandbagId}" doesn't exist.</p>
			<a href="{base}/">← Back to Dashboard</a>
		</div>
	{/if}
</div>

<style>
	.sandbag-view {
		display: flex;
		flex-direction: column;
		gap: 1rem;
		height: calc(100vh - 80px);
	}

	.view-header {
		display: flex;
		align-items: center;
		gap: 0.75rem;
		flex-wrap: wrap;
		flex-shrink: 0;
	}

	.back-link {
		font-size: 0.875rem;
		color: var(--color-text-muted);
	}

	.header-icon {
		font-size: 1.25rem;
	}

	.view-header h1 {
		font-size: 1.25rem;
		margin: 0;
	}

	.header-type {
		font-size: 0.75rem;
		text-transform: uppercase;
		letter-spacing: 0.05em;
		color: var(--color-text-muted);
		background: var(--color-bg);
		padding: 0.2rem 0.5rem;
		border-radius: 4px;
	}

	.view-actions {
		margin-left: auto;
		display: flex;
		gap: 0.5rem;
	}

	.iframe-container {
		flex: 1;
		border: 1px solid var(--color-border);
		border-radius: var(--radius);
		overflow: hidden;
		background: white;
	}

	.iframe-container iframe {
		width: 100%;
		height: 100%;
		border: none;
	}

	.not-found {
		text-align: center;
		padding: 4rem 2rem;
		color: var(--color-text-muted);
	}

	.not-found h2 {
		color: var(--color-text);
		margin-bottom: 0.5rem;
	}
</style>
