export interface LeveeConfig {
	httpUrl: string;
	socketUrl: string;
	tenantId: string;
	authToken?: string;
	documentId?: string;
}

const defaults = {
	httpUrl: "http://localhost:4000",
	socketUrl: "ws://localhost:4000/socket",
	tenantId: "sandbag",
};

/**
 * Parse Levee connection config from URL search params, falling back to defaults.
 */
export function parseConfigFromParams(params: URLSearchParams): LeveeConfig {
	return {
		httpUrl: params.get("httpUrl") ?? defaults.httpUrl,
		socketUrl: params.get("socketUrl") ?? defaults.socketUrl,
		tenantId: params.get("tenantId") ?? defaults.tenantId,
		authToken: params.get("authToken") ?? undefined,
		documentId: params.get("documentId") ?? undefined,
	};
}
