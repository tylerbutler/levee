<script lang="ts">
import "../app.css";
import { onMount } from "svelte";
import { goto } from "$app/navigation";
import { base } from "$app/paths";
import { page } from "$app/state";
import {
	checkSession,
	getAuthUser,
	hasCheckedSession,
	isAuthenticated,
	logout,
} from "$lib/auth.svelte";

let { children } = $props();

const isLoginPage = $derived(page.url.pathname.endsWith("/login"));
const isAppPage = $derived(page.url.pathname.includes("/apps/"));

onMount(async () => {
	// App pages are standalone; auth is handled via URL params or localStorage
	if (isAppPage) return;

	await checkSession();
	if (!isAuthenticated() && !isLoginPage) {
		goto(`${base}/login`);
	}
});

// Redirect when auth state changes (e.g., after logout)
$effect(() => {
	if (hasCheckedSession() && !isAuthenticated() && !isLoginPage && !isAppPage) {
		goto(`${base}/login`);
	}
});

const authUser = $derived(getAuthUser());

async function handleLogout() {
	await logout();
	goto(`${base}/login`);
}
</script>

<div class="app-shell">
	<header class="app-header">
		<a href="{base}/" class="logo">
			<span class="logo-icon">🏖️</span>
			<span class="logo-text">Sandbag</span>
		</a>
		<span class="tagline">Levee Testing Hub</span>

		{#if authUser && !isLoginPage}
			<div class="user-info">
				<span class="user-name">{authUser.display_name ?? authUser.email}</span>
				<button class="btn-outline btn-sm" onclick={handleLogout}>
					Log out
				</button>
			</div>
		{/if}
	</header>

	<main class="app-main">
		{@render children()}
	</main>
</div>

<style>
	.app-shell {
		min-height: 100vh;
		display: flex;
		flex-direction: column;
	}

	.app-header {
		display: flex;
		align-items: center;
		gap: 1rem;
		padding: 0.75rem 1.5rem;
		background: var(--color-surface);
		border-bottom: 1px solid var(--color-border);
		box-shadow: var(--shadow);
	}

	.logo {
		display: flex;
		align-items: center;
		gap: 0.5rem;
		text-decoration: none;
		color: var(--color-text);
		font-weight: 700;
		font-size: 1.25rem;
	}

	.logo:hover {
		text-decoration: none;
	}

	.logo-icon {
		font-size: 1.5rem;
	}

	.tagline {
		color: var(--color-text-muted);
		font-size: 0.875rem;
	}

	.user-info {
		margin-left: auto;
		display: flex;
		align-items: center;
		gap: 0.75rem;
	}

	.user-name {
		font-size: 0.875rem;
		color: var(--color-text-muted);
	}

	.btn-sm {
		padding: 0.25rem 0.625rem;
		font-size: 0.8125rem;
	}

	.app-main {
		flex: 1;
		padding: 1.5rem;
		max-width: 1200px;
		width: 100%;
		margin: 0 auto;
	}
</style>
