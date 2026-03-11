export interface LeveeConfig {
	httpUrl: string;
	socketUrl: string;
	tenantId: string;
	tenantKey: string;
	documentId?: string;
}

const defaults: Omit<LeveeConfig, "documentId"> = {
	httpUrl: "http://localhost:4000",
	socketUrl: "ws://localhost:4000/socket",
	tenantId: "fluid",
	tenantKey: "dev-tenant-secret-key",
};

/**
 * Parse Levee connection config from URL search params, falling back to defaults.
 */
export function parseConfigFromParams(params: URLSearchParams): LeveeConfig {
	return {
		httpUrl: params.get("httpUrl") ?? defaults.httpUrl,
		socketUrl: params.get("socketUrl") ?? defaults.socketUrl,
		tenantId: params.get("tenantId") ?? defaults.tenantId,
		tenantKey: params.get("tenantKey") ?? defaults.tenantKey,
		documentId: params.get("documentId") ?? undefined,
	};
}
