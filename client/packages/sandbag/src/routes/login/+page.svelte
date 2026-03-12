<script lang="ts">
import { onMount } from "svelte";
import { goto } from "$app/navigation";
import { base } from "$app/paths";
import { page } from "$app/state";
import { isAuthenticated, setTokenFromOAuth } from "$lib/auth.svelte";

let error = $state<string | undefined>();
let loading = $state(false);

// The OAuth callback redirects here with ?token=SESSION_ID
onMount(async () => {
	const callbackToken = page.url.searchParams.get("token");
	const callbackError = page.url.searchParams.get("error");

	if (callbackError) {
		error =
			callbackError === "not_authorized"
				? "Your GitHub account is not authorized to access this application."
				: `Authentication failed: ${callbackError}`;
		return;
	}

	if (callbackToken) {
		loading = true;
		const user = await setTokenFromOAuth(callbackToken);
		if (user) {
			goto(`${base}/`);
		} else {
			error = "Session token was invalid. Please try again.";
			loading = false;
		}
		return;
	}

	// Already logged in, redirect to dashboard
	if (isAuthenticated()) {
		goto(`${base}/`);
	}
});

function loginWithGitHub() {
	const redirectUrl = `${window.location.origin}${base}/login`;
	window.location.href = `/auth/github?redirect_url=${encodeURIComponent(redirectUrl)}`;
}
</script>

<div class="login-page">
	<div class="login-card">
		<div class="login-header">
			<span class="login-icon">🏖️</span>
			<h1>Sandbag</h1>
			<p class="login-subtitle">Levee Testing Hub</p>
		</div>

		{#if error}
			<div class="error-message">{error}</div>
		{/if}

		{#if loading}
			<p class="loading-text">Signing in...</p>
		{:else}
			<button class="github-btn" onclick={loginWithGitHub}>
				<svg viewBox="0 0 16 16" width="20" height="20" fill="currentColor" aria-hidden="true">
					<path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z"></path>
				</svg>
				Sign in with GitHub
			</button>
		{/if}
	</div>
</div>

<style>
	.login-page {
		display: flex;
		align-items: center;
		justify-content: center;
		min-height: calc(100vh - 120px);
	}

	.login-card {
		background: var(--color-surface);
		border: 1px solid var(--color-border);
		border-radius: var(--radius);
		padding: 2rem;
		width: 100%;
		max-width: 400px;
		box-shadow: var(--shadow-md);
	}

	.login-header {
		text-align: center;
		margin-bottom: 1.5rem;
	}

	.login-icon {
		font-size: 2.5rem;
		display: block;
		margin-bottom: 0.5rem;
	}

	.login-header h1 {
		font-size: 1.5rem;
		margin-bottom: 0.25rem;
	}

	.login-subtitle {
		color: var(--color-text-muted);
		font-size: 0.875rem;
	}

	.error-message {
		background: #fef2f2;
		color: #dc2626;
		padding: 0.625rem 0.875rem;
		border-radius: var(--radius);
		font-size: 0.875rem;
		margin-bottom: 1rem;
	}

	.loading-text {
		text-align: center;
		color: var(--color-text-muted);
		font-size: 0.9375rem;
	}

	.github-btn {
		width: 100%;
		display: flex;
		align-items: center;
		justify-content: center;
		gap: 0.625rem;
		padding: 0.625rem;
		font-size: 0.9375rem;
		font-weight: 500;
		background: #24292f;
		color: white;
		border: none;
		border-radius: var(--radius);
		cursor: pointer;
		transition: background-color 0.15s;
	}

	.github-btn:hover {
		background: #32383f;
	}
</style>
