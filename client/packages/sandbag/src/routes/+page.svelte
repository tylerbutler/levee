<script lang="ts">
import { buildAppUrl } from "$lib/api";
import { getAuthToken } from "$lib/auth.svelte";
import { loadAllApps } from "$lib/registry";
import type { SandbagApp } from "$lib/types";

interface Document {
	id: string;
	tenantId: string;
	sequenceNumber: number;
	sessionAlive: boolean;
	appName: string | null;
	appVersion: string | null;
}

let apps = $state<SandbagApp[]>([]);
let documents = $state<Document[]>([]);
let appsLoaded = $state(false);
let docsLoading = $state(true);
let docsError = $state<string | undefined>();

/** Map from package name → app descriptor for reverse lookup. */
let appsByPackage = $derived(new Map(apps.map((a) => [a.packageName, a])));

function appForDocument(doc: Document): SandbagApp | undefined {
	if (!doc.appName) return undefined;
	return appsByPackage.get(doc.appName);
}

$effect(() => {
	loadAllApps().then((loaded) => {
		apps = loaded;
		appsLoaded = true;
	});
	fetchDocuments();
});

async function fetchDocuments() {
	const token = getAuthToken();
	if (!token) {
		docsLoading = false;
		return;
	}

	try {
		const res = await fetch(`/api/documents/sandbag`, {
			headers: { Authorization: `Bearer ${token}` },
		});
		if (!res.ok) {
			docsError = `Failed to load documents (${res.status})`;
			docsLoading = false;
			return;
		}
		const data = (await res.json()) as { documents: Document[] };
		documents = data.documents;
	} catch (err) {
		docsError = err instanceof Error ? err.message : String(err);
	}
	docsLoading = false;
}
</script>

<div class="dashboard">
	<div class="dashboard-header">
		<h1>Sandbags</h1>
	</div>

	<section>
		<h2>New</h2>
		{#if !appsLoaded}
			<div class="loading">Loading apps…</div>
		{:else}
			<div class="app-grid">
				{#each apps as app (app.id)}
					<a href={buildAppUrl(app.id)} class="app-card">
						<span class="card-icon">{app.icon}</span>
						<h3 class="card-name">{app.label}</h3>
						<p class="card-desc">{app.description}</p>
					</a>
				{/each}
			</div>
		{/if}
	</section>

	<section>
		<h2>Documents</h2>
		{#if docsLoading}
			<div class="loading">Loading documents…</div>
		{:else if docsError}
			<div class="error">{docsError}</div>
		{:else if documents.length === 0}
			<p class="empty">No documents yet. Create one by selecting an app above.</p>
		{:else}
			<div class="doc-list">
				{#each documents as doc (doc.id)}
					{@const app = appForDocument(doc)}
					<div class="doc-row">
						{#if app}
							<a href={buildAppUrl(app.id, doc.id)} class="doc-link" title="Open as {app.label}">
								<span class="doc-icon">{app.icon}</span>
								<span class="doc-id">{doc.id}</span>
							</a>
						{:else}
							<span class="doc-icon">📄</span>
							<span class="doc-id">{doc.id}</span>
						{/if}
						<span class="doc-app-name">{app?.label ?? doc.appName ?? "Unknown"}</span>
						<span class="doc-seq">seq {doc.sequenceNumber}</span>
						{#if doc.sessionAlive}
							<span class="doc-status active">active</span>
						{:else}
							<span class="doc-status">idle</span>
						{/if}
					</div>
				{/each}
			</div>
		{/if}
	</section>
</div>

<style>
	.dashboard {
		display: flex;
		flex-direction: column;
		gap: 2rem;
	}

	.dashboard-header h1 {
		font-size: 1.75rem;
	}

	section h2 {
		font-size: 1.25rem;
		margin-bottom: 0.75rem;
		color: var(--color-text);
	}

	.loading {
		text-align: center;
		padding: 2rem;
		color: var(--color-text-muted);
	}

	.error {
		color: #dc2626;
		padding: 1rem;
	}

	.empty {
		color: var(--color-text-muted);
		padding: 1rem 0;
	}

	.app-grid {
		display: grid;
		grid-template-columns: repeat(auto-fill, minmax(240px, 1fr));
		gap: 1rem;
	}

	.app-card {
		background: var(--color-surface);
		border: 1px solid var(--color-border);
		border-radius: var(--radius);
		padding: 1.25rem;
		box-shadow: var(--shadow);
		transition: box-shadow 0.15s;
		text-decoration: none;
		color: inherit;
		display: block;
	}

	.app-card:hover {
		box-shadow: var(--shadow-md);
	}

	.card-icon {
		font-size: 2rem;
		display: block;
		margin-bottom: 0.75rem;
	}

	.card-name {
		font-size: 1.125rem;
		margin-bottom: 0.25rem;
	}

	.card-desc {
		font-size: 0.8125rem;
		color: var(--color-text-muted);
	}

	.doc-list {
		display: flex;
		flex-direction: column;
		border: 1px solid var(--color-border);
		border-radius: var(--radius);
		overflow: hidden;
	}

	.doc-row {
		display: flex;
		align-items: center;
		gap: 1rem;
		padding: 0.75rem 1rem;
		border-bottom: 1px solid var(--color-border);
	}

	.doc-row:last-child {
		border-bottom: none;
	}

	.doc-id {
		font-family: monospace;
		font-size: 0.875rem;
	}

	.doc-seq {
		font-size: 0.75rem;
		color: var(--color-text-muted);
	}

	.doc-status {
		font-size: 0.75rem;
		padding: 0.125rem 0.5rem;
		border-radius: 9999px;
		background: var(--color-bg);
		color: var(--color-text-muted);
	}

	.doc-status.active {
		background: #dcfce7;
		color: #166534;
	}

	.doc-link {
		display: flex;
		align-items: center;
		gap: 0.5rem;
		text-decoration: none;
		color: inherit;
	}

	.doc-link:hover .doc-id {
		text-decoration: underline;
	}

	.doc-icon {
		font-size: 1.25rem;
		flex-shrink: 0;
	}

	.doc-app-name {
		font-size: 0.75rem;
		color: var(--color-text-muted);
		margin-left: auto;
	}
</style>
