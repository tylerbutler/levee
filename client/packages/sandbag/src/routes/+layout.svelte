<script lang="ts">
import "../app.css";
import { base } from "$app/paths";

let { children } = $props();
</script>

<div class="app-shell">
	<header class="app-header">
		<a href="{base}/" class="logo">
			<span class="logo-icon">🏖️</span>
			<span class="logo-text">Sandbag</span>
		</a>
		<span class="tagline">Levee Testing Hub</span>
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

	.app-main {
		flex: 1;
		padding: 1.5rem;
		max-width: 1200px;
		width: 100%;
		margin: 0 auto;
	}
</style>
