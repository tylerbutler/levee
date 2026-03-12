<script lang="ts">
import { onDestroy, onMount } from "svelte";
import { goto } from "$app/navigation";
import { base } from "$app/paths";
import { page } from "$app/state";
import { getSandbag, updateSandbag } from "$lib/api";
import { getAuthToken } from "$lib/auth.svelte";
import { parseConfigFromParams } from "$lib/config";
import { loadApp } from "$lib/registry";
import type { SandbagApp } from "$lib/types";

const sandbagId = $derived(page.params.id);
const sandbag = $derived(getSandbag(sandbagId));

// Document ID and app type can come from query params (shared link) or localStorage record
const params = $derived(new URLSearchParams(page.url.search));
const appType = $derived(params.get("appType") ?? sandbag?.appType);
const documentId = $derived(
	params.get("documentId") ?? (sandbag?.documentId || undefined),
);

let container: HTMLDivElement;
let unmount: (() => void) | undefined;
let error = $state<string | undefined>();
let loading = $state(true);
let appInfo = $state<SandbagApp | undefined>();
let shareUrl = $state<string | undefined>();

onMount(async () => {
	if (!appType) {
		error = sandbag
			? `Unknown app type`
			: `Sandbag "${sandbagId}" not found. The link may have been created on another device.`;
		loading = false;
		return;
	}

	try {
		const app = await loadApp(appType);
		if (!app) {
			error = `Unknown app type: ${appType}`;
			loading = false;
			return;
		}
		appInfo = app;

		const baseConfig = parseConfigFromParams(params);
		const authToken = getAuthToken();
		const config = {
			...baseConfig,
			...(authToken ? { authToken } : {}),
			...(documentId ? { documentId } : {}),
		};

		const result = await app.mount(container, config);
		unmount = result.unmount;

		// Persist documentId to localStorage if we have a record
		if (
			sandbag &&
			result.documentId &&
			result.documentId !== sandbag.documentId
		) {
			updateSandbag(sandbagId, { documentId: result.documentId });
		}

		// Update URL with documentId and appType so the link is self-contained
		const url = new URL(window.location.href);
		let urlChanged = false;
		if (
			result.documentId &&
			url.searchParams.get("documentId") !== result.documentId
		) {
			url.searchParams.set("documentId", result.documentId);
			urlChanged = true;
		}
		if (appType && !url.searchParams.has("appType")) {
			url.searchParams.set("appType", appType);
			urlChanged = true;
		}
		if (urlChanged) {
			await goto(`${url.pathname}${url.search}`, { replaceState: true });
		}
		shareUrl = url.toString();
	} catch (err) {
		error = err instanceof Error ? err.message : String(err);
	}
	loading = false;
});

onDestroy(() => unmount?.());

function copyShareLink() {
	if (shareUrl) {
		navigator.clipboard.writeText(shareUrl);
	}
}
</script>

<div class="sandbag-view">
	<div class="view-header">
		<a href="{base}/" class="back-link">← Dashboard</a>
		{#if appInfo}
			<span class="header-icon">{appInfo.icon}</span>
		{/if}
		<h1>{sandbag?.name ?? appInfo?.label ?? "Sandbag"}</h1>
		{#if appInfo}
			<span class="header-type">{appInfo.label}</span>
		{/if}
		<div class="view-actions">
			<button class="btn-outline" onclick={copyShareLink} disabled={!shareUrl}>
				📋 Copy Link
			</button>
			<button
				class="btn-outline"
				onclick={() => {
					if (shareUrl) window.open(shareUrl, "_blank");
				}}
				disabled={!shareUrl}
			>
				↗ New Tab
			</button>
		</div>
	</div>

	{#if error}
		<div class="error">
			<p>Failed to load app: {error}</p>
		</div>
	{/if}

	{#if loading}
		<div class="loading">Loading {appType}…</div>
	{/if}

	<div
		bind:this={container}
		class="app-container"
		class:hidden={loading || !!error}
	></div>
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

	.app-container {
		flex: 1;
		border: 1px solid var(--color-border);
		border-radius: var(--radius);
		overflow: hidden;
		background: white;
	}

	.hidden {
		display: none;
	}

	.loading,
	.error {
		display: flex;
		align-items: center;
		justify-content: center;
		min-height: 200px;
		font-size: 1rem;
		color: #64748b;
	}

	.error {
		color: #dc2626;
	}
</style>
