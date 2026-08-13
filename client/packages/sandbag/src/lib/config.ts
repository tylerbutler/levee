export interface LeveeConfig {
	/** HTTP URL of the service. */
	httpUrl?: string;
	/**
	 * WebSocket URL of the service. When absent, the mounted app applies its
	 * own default.
	 */
	socketUrl?: string;
	/**
	 * Tenant ID. When absent, the mounted app applies its own default.
	 */
	tenantId?: string;
	authToken?: string;
	documentId?: string;
}

/**
 * Parse service connection config from URL search params.
 *
 * All fields are optional: values absent from params are returned as
 * `undefined` so that each app's mount function can apply its own defaults
 * rather than inheriting Levee-specific or origin-derived fallbacks.
 */
export function parseConfigFromParams(params: URLSearchParams): LeveeConfig {
	return {
		httpUrl: params.get("httpUrl") ?? undefined,
		socketUrl: params.get("socketUrl") ?? undefined,
		tenantId: params.get("tenantId") ?? undefined,
		authToken: params.get("authToken") ?? undefined,
		documentId: params.get("documentId") ?? undefined,
	};
}
