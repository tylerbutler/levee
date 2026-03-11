<script lang="ts">
import { base } from "$app/paths";
import {
	createSandbag,
	deleteSandbag,
	listSandbags,
	type SandbagRecord,
} from "$lib/api";
import { type AppType, loadAllApps } from "$lib/registry";
import type { SandbagApp } from "$lib/types";

let showCreateDialog = $state(false);
let newSandbagName = $state("");
let selectedAppType = $state("dice-roller");
let sandbags = $state<SandbagRecord[]>([]);
let apps = $state<SandbagApp[]>([]);
let appsLoaded = $state(false);

$effect(() => {
	sandbags = listSandbags();
	loadAllApps().then((loaded) => {
		apps = loaded;
		appsLoaded = true;
	});
});

function appInfo(type: string): SandbagApp | undefined {
	return apps.find((a) => a.id === type);
}

function handleCreate() {
	if (!newSandbagName.trim()) return;
	createSandbag(newSandbagName.trim(), selectedAppType);
	sandbags = listSandbags();
	newSandbagName = "";
	showCreateDialog = false;
}

function handleDelete(id: string) {
	deleteSandbag(id);
	sandbags = listSandbags();
}
</script>

<div class="dashboard">
	<div class="dashboard-header">
		<h1>Sandbags</h1>
		<button class="btn-primary" onclick={() => (showCreateDialog = true)}>
			+ New Sandbag
		</button>
	</div>

	{#if sandbags.length === 0}
		<div class="empty-state">
			<div class="empty-icon">🏖️</div>
			<h2>No sandbags yet</h2>
			<p>Create your first sandbag to start testing collaborative apps.</p>
			<button class="btn-primary" onclick={() => (showCreateDialog = true)}>
				Create a Sandbag
			</button>
		</div>
	{:else}
		<div class="sandbag-grid">
			{#each sandbags as sandbag (sandbag.id)}
				{@const info = appInfo(sandbag.appType)}
				<div class="sandbag-card">
					<div class="card-header">
						<span class="card-icon">{info?.icon ?? "📦"}</span>
						<span class="card-type">{info?.label ?? sandbag.appType}</span>
					</div>
					<h3 class="card-name">{sandbag.name}</h3>
					<p class="card-meta">
						Created {new Date(sandbag.createdAt).toLocaleDateString()}
					</p>
					<div class="card-actions">
						<a href="{base}/sandbag/{sandbag.id}" class="btn-primary">
							Open
						</a>
						<button
							class="btn-danger"
							onclick={() => handleDelete(sandbag.id)}
						>
							Delete
						</button>
					</div>
				</div>
			{/each}
		</div>
	{/if}

	{#if showCreateDialog && appsLoaded}
		<!-- svelte-ignore a11y_click_events_have_key_events -->
		<!-- svelte-ignore a11y_no_static_element_interactions -->
		<div class="dialog-overlay" onclick={() => (showCreateDialog = false)}>
			<div class="dialog" onclick={(e) => e.stopPropagation()}>
				<h2>Create a new Sandbag</h2>

				<label class="field">
					<span>Name</span>
					<input
						type="text"
						bind:value={newSandbagName}
						placeholder="My test sandbag"
					/>
				</label>

				<fieldset class="field">
					<legend>App Type</legend>
					<div class="app-type-grid">
						{#each apps as app}
							<label
								class="app-type-option"
								class:selected={selectedAppType === app.id}
							>
								<input
									type="radio"
									name="appType"
									value={app.id}
									bind:group={selectedAppType}
								/>
								<span class="app-type-icon">{app.icon}</span>
								<span class="app-type-label">{app.label}</span>
								<span class="app-type-desc">{app.description}</span>
							</label>
						{/each}
					</div>
				</fieldset>

				<div class="dialog-actions">
					<button
						class="btn-outline"
						onclick={() => (showCreateDialog = false)}
					>
						Cancel
					</button>
					<button class="btn-primary" onclick={handleCreate}>
						Create
					</button>
				</div>
			</div>
		</div>
	{/if}
</div>

<style>
	.dashboard {
		display: flex;
		flex-direction: column;
		gap: 1.5rem;
	}

	.dashboard-header {
		display: flex;
		justify-content: space-between;
		align-items: center;
	}

	.dashboard-header h1 {
		font-size: 1.75rem;
	}

	.empty-state {
		text-align: center;
		padding: 4rem 2rem;
		background: var(--color-surface);
		border-radius: var(--radius);
		border: 1px solid var(--color-border);
	}

	.empty-icon {
		font-size: 3rem;
		margin-bottom: 1rem;
	}

	.empty-state h2 {
		margin-bottom: 0.5rem;
		color: var(--color-text);
	}

	.empty-state p {
		color: var(--color-text-muted);
		margin-bottom: 1.5rem;
	}

	.sandbag-grid {
		display: grid;
		grid-template-columns: repeat(auto-fill, minmax(280px, 1fr));
		gap: 1rem;
	}

	.sandbag-card {
		background: var(--color-surface);
		border: 1px solid var(--color-border);
		border-radius: var(--radius);
		padding: 1.25rem;
		box-shadow: var(--shadow);
		transition: box-shadow 0.15s;
	}

	.sandbag-card:hover {
		box-shadow: var(--shadow-md);
	}

	.card-header {
		display: flex;
		align-items: center;
		gap: 0.5rem;
		margin-bottom: 0.75rem;
	}

	.card-icon {
		font-size: 1.25rem;
	}

	.card-type {
		font-size: 0.75rem;
		text-transform: uppercase;
		letter-spacing: 0.05em;
		color: var(--color-text-muted);
		font-weight: 600;
	}

	.card-name {
		font-size: 1.125rem;
		margin-bottom: 0.25rem;
	}

	.card-meta {
		font-size: 0.8125rem;
		color: var(--color-text-muted);
		margin-bottom: 1rem;
	}

	.card-actions {
		display: flex;
		gap: 0.5rem;
	}

	.card-actions a {
		text-decoration: none;
		display: inline-flex;
		align-items: center;
		justify-content: center;
		padding: 0.5rem 1rem;
		border-radius: var(--radius);
		font-size: 0.875rem;
		font-weight: 500;
	}

	.dialog-overlay {
		position: fixed;
		inset: 0;
		background: rgba(0, 0, 0, 0.4);
		display: flex;
		align-items: center;
		justify-content: center;
		z-index: 100;
	}

	.dialog {
		background: var(--color-surface);
		border-radius: var(--radius);
		padding: 1.5rem;
		width: 90%;
		max-width: 500px;
		box-shadow: var(--shadow-md);
	}

	.dialog h2 {
		margin-bottom: 1.25rem;
	}

	.field {
		display: flex;
		flex-direction: column;
		gap: 0.375rem;
		margin-bottom: 1rem;
		border: none;
		padding: 0;
	}

	.field span,
	.field legend {
		font-size: 0.875rem;
		font-weight: 500;
		color: var(--color-text);
	}

	.field input[type="text"] {
		padding: 0.5rem 0.75rem;
		border: 1px solid var(--color-border);
		border-radius: var(--radius);
		font-size: 0.9375rem;
	}

	.app-type-grid {
		display: flex;
		flex-direction: column;
		gap: 0.5rem;
		margin-top: 0.25rem;
	}

	.app-type-option {
		display: grid;
		grid-template-columns: auto auto 1fr;
		grid-template-rows: auto auto;
		gap: 0 0.5rem;
		padding: 0.75rem;
		border: 1px solid var(--color-border);
		border-radius: var(--radius);
		cursor: pointer;
		transition: border-color 0.15s;
	}

	.app-type-option:hover {
		border-color: var(--color-primary);
	}

	.app-type-option.selected {
		border-color: var(--color-primary);
		background: #eff6ff;
	}

	.app-type-option input[type="radio"] {
		display: none;
	}

	.app-type-icon {
		grid-row: 1 / 3;
		font-size: 1.5rem;
		display: flex;
		align-items: center;
	}

	.app-type-label {
		font-weight: 600;
		font-size: 0.9375rem;
	}

	.app-type-desc {
		grid-column: 2 / 4;
		font-size: 0.8125rem;
		color: var(--color-text-muted);
	}

	.dialog-actions {
		display: flex;
		justify-content: flex-end;
		gap: 0.5rem;
		margin-top: 1.5rem;
	}
</style>
