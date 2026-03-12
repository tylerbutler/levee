const TOKEN_KEY = "sandbag:authToken";

export interface AuthUser {
	id: string;
	email: string;
	display_name: string | null;
	is_admin: boolean;
}

let token = $state<string | null>(
	typeof localStorage !== "undefined" ? localStorage.getItem(TOKEN_KEY) : null,
);
let user = $state<AuthUser | null>(null);
let checked = $state(false);

export function getAuthToken(): string | null {
	return token;
}

export function getAuthUser(): AuthUser | null {
	return user;
}

export function isAuthenticated(): boolean {
	return token !== null;
}

export function hasCheckedSession(): boolean {
	return checked;
}

function apiBase(): string {
	return typeof window !== "undefined" ? window.location.origin : "";
}

function setAuth(newToken: string, newUser: AuthUser) {
	token = newToken;
	user = newUser;
	checked = true;
	localStorage.setItem(TOKEN_KEY, newToken);
}

function clearAuth() {
	token = null;
	user = null;
	checked = true;
	localStorage.removeItem(TOKEN_KEY);
}

/**
 * Store a session token received from an OAuth callback redirect.
 * Validates the token by calling /api/auth/me.
 */
export async function setTokenFromOAuth(
	sessionToken: string,
): Promise<AuthUser | null> {
	token = sessionToken;
	localStorage.setItem(TOKEN_KEY, sessionToken);

	const result = await checkSession();
	if (!result) {
		clearAuth();
	}
	return result;
}

/**
 * Check if the stored session is still valid. Returns the user if so.
 */
export async function checkSession(): Promise<AuthUser | null> {
	if (!token) {
		checked = true;
		return null;
	}

	try {
		const res = await fetch(`${apiBase()}/api/auth/me`, {
			headers: { Authorization: `Bearer ${token}` },
		});
		if (!res.ok) {
			clearAuth();
			return null;
		}
		const data = (await res.json()) as { user: AuthUser };
		user = data.user;
		checked = true;
		return data.user;
	} catch {
		clearAuth();
		return null;
	}
}

/**
 * Log out and clear local session state.
 */
export async function logout(): Promise<void> {
	const currentToken = token;
	if (currentToken) {
		try {
			await fetch(`${apiBase()}/api/auth/logout`, {
				method: "POST",
				headers: { Authorization: `Bearer ${currentToken}` },
			});
		} catch {
			// Best-effort server logout
		}
	}
	clearAuth();
}
