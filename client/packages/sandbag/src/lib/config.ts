export interface LeveeConfig {
	httpUrl: string;
	socketUrl: string;
	tenantId: string;
	authToken?: string;
	documentId?: string;
}

function getDefaults() {
	if (typeof window === "undefined") {
		return {
			httpUrl: "http://localhost:4000",
			socketUrl: "ws://localhost:4000/socket",
		};
	}
	const origin = window.location.origin;
	const wsProtocol = window.location.protocol === "https:" ? "wss:" : "ws:";
	return {
		httpUrl: origin,
		socketUrl: `${wsProtocol}//${window.location.host}/socket`,
	};
}

/**
 * Parse Levee connection config from URL search params, falling back to defaults.
 */
export function parseConfigFromParams(params: URLSearchParams): LeveeConfig {
	const defaults = getDefaults();
	return {
		httpUrl: params.get("httpUrl") ?? defaults.httpUrl,
		socketUrl: params.get("socketUrl") ?? defaults.socketUrl,
		tenantId: params.get("tenantId") ?? "sandbag",
		authToken: params.get("authToken") ?? undefined,
		documentId: params.get("documentId") ?? undefined,
	};
}
