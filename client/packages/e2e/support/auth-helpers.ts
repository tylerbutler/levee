const API_BASE = "http://localhost:4000/api";

interface AuthUser {
	id: string;
	email: string;
	display_name: string;
}

interface AuthResponse {
	user: AuthUser;
	token: string;
}

/**
 * Register a new user via the REST API and return the session token.
 * Uses a unique email to avoid conflicts between test runs.
 */
export async function registerUser(
	displayName = "Test User",
): Promise<AuthResponse> {
	const uniqueId = `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
	const email = `test-${uniqueId}@example.com`;
	const password = "testpassword123";

	const response = await fetch(`${API_BASE}/auth/register`, {
		method: "POST",
		headers: { "Content-Type": "application/json" },
		body: JSON.stringify({
			email,
			password,
			display_name: displayName,
		}),
	});

	if (!response.ok) {
		const body = await response.text();
		throw new Error(`Failed to register user: ${response.status} ${body}`);
	}

	return response.json();
}
