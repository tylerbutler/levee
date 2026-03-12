import { base } from "$app/paths";

/**
 * Build the app URL for a given app type.
 * The documentId is part of the path: /apps/{type}/{documentId}
 */
export function buildAppUrl(appType: string, documentId?: string): string {
	if (documentId) {
		return `${base}/apps/${appType}/${documentId}`;
	}
	return `${base}/apps/${appType}`;
}
