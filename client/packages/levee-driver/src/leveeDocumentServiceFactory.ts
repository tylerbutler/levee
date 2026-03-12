/**
 * Document service factory for Levee server.
 */

import type { ITelemetryBaseLogger } from "@fluidframework/core-interfaces";
import type {
	IDocumentService,
	IDocumentServiceFactory,
	IResolvedUrl,
} from "@fluidframework/driver-definitions/internal";
import type { ISummaryTree } from "@fluidframework/protocol-definitions";
import type { ITokenProvider } from "@fluidframework/routerlicious-driver";
import {
	isDebugEnabled,
	LeveeDebugLogger,
	type LeveeResolvedUrl,
	type SerializationFormat,
} from "./contracts.js";
import { LeveeDocumentService } from "./leveeDocumentService.js";
import { RestWrapper } from "./restWrapper.js";

/**
 * Protocol identifier for this document service factory.
 */
const LEVEE_PROTOCOL_NAME = "levee";

/**
 * Document service factory for Levee server.
 *
 * @remarks
 * Creates document services that connect to a Levee Fluid server.
 * This is the main entry point for the Levee driver.
 *
 * @example
 * ```typescript
 * const tokenProvider = new InsecureLeveeTokenProvider(
 *   "tenant-secret-key",
 *   { id: "user-123", name: "Test User" }
 * );
 *
 * const factory = new LeveeDocumentServiceFactory(tokenProvider);
 *
 * // Use with Fluid container loader
 * const loader = new Loader({
 *   urlResolver,
 *   documentServiceFactory: factory,
 *   codeLoader,
 * });
 * ```
 *
 * @public
 */
export class LeveeDocumentServiceFactory implements IDocumentServiceFactory {
	/**
	 * Protocol name for this factory.
	 */
	public readonly protocolName = LEVEE_PROTOCOL_NAME;

	private readonly tokenProvider: ITokenProvider;
	private readonly debug: boolean;
	private _serialization: SerializationFormat;
	private readonly logger: LeveeDebugLogger;

	/**
	 * Creates a new LeveeDocumentServiceFactory.
	 *
	 * @param tokenProvider - Token provider for authentication
	 * @param debug - Whether to enable debug logging
	 * @param serialization - Serialization format for WebSocket channels (default: "json")
	 */
	public constructor(
		tokenProvider: ITokenProvider,
		debug?: boolean,
		serialization?: SerializationFormat,
	) {
		this.tokenProvider = tokenProvider;
		this.debug = isDebugEnabled(debug);
		this._serialization = serialization ?? "json";
		this.logger = new LeveeDebugLogger("Factory", this.debug);
	}

	/**
	 * The serialization format used for new WebSocket connections.
	 *
	 * @remarks
	 * Changing this value affects only *future* connections. Existing connections
	 * continue using whatever format they were created with. To force a reconnect
	 * with the new format, dispose the current connection — the Fluid runtime will
	 * call {@link LeveeDocumentService.connectToDeltaStream} again automatically.
	 */
	public get serialization(): SerializationFormat {
		return this._serialization;
	}

	public set serialization(format: SerializationFormat) {
		this._serialization = format;
		this.logger.log(`Serialization format changed to ${format}`);
	}

	/**
	 * Creates a document service for an existing document.
	 *
	 * @param resolvedUrl - Resolved URL containing document connection info
	 * @param logger - Optional telemetry logger
	 * @param clientIsSummarizer - Whether the client is a summarizer
	 * @returns Document service instance
	 */
	public async createDocumentService(
		resolvedUrl: IResolvedUrl,
		_logger?: ITelemetryBaseLogger,
		_clientIsSummarizer?: boolean,
	): Promise<IDocumentService> {
		this.logger.log(
			`Creating document service for ${(resolvedUrl as LeveeResolvedUrl).documentId}`,
		);
		return new LeveeDocumentService(
			resolvedUrl,
			this.tokenProvider,
			this.debug,
			this._serialization,
		);
	}

	/**
	 * Creates a new document container on the server.
	 *
	 * @remarks
	 * This method creates a new document on the server and returns a document
	 * service connected to it. The summary tree is used to initialize the
	 * document's initial state.
	 *
	 * @param createNewSummary - Initial summary tree for the new document
	 * @param createNewResolvedUrl - Resolved URL for document creation
	 * @param logger - Optional telemetry logger
	 * @param clientIsSummarizer - Whether the client is a summarizer
	 * @returns Document service connected to the new document
	 */
	public async createContainer(
		createNewSummary: ISummaryTree | undefined,
		createNewResolvedUrl: IResolvedUrl,
		_logger?: ITelemetryBaseLogger,
		_clientIsSummarizer?: boolean,
	): Promise<IDocumentService> {
		const leveeUrl = createNewResolvedUrl as LeveeResolvedUrl;

		this.logger.log(`Creating container for tenant: ${leveeUrl.tenantId}`);

		// Create the document on the server - server generates the document ID
		// Use a placeholder document ID for the creation token since the server
		// will generate and return the actual ID
		const restWrapper = new RestWrapper(
			leveeUrl.httpUrl,
			this.tokenProvider,
			leveeUrl.tenantId,
			"__new__", // Placeholder for new document creation
			30000, // default timeout
			this.debug,
		);

		// Build request body — include initial summary if provided so the server
		// can persist the snapshot as git objects (blobs, trees, commit, ref).
		// Without this, other clients cannot load the container.
		const body: Record<string, unknown> = createNewSummary
			? { summary: createNewSummary }
			: {};

		// Create document - server generates and returns the document ID
		const documentId = await restWrapper.post<string>(
			`/documents/${leveeUrl.tenantId}`,
			body,
		);

		this.logger.log(`Container created with ID: ${documentId}`);

		// Update resolved URL with the document ID from server
		const updatedUrl: LeveeResolvedUrl = {
			...leveeUrl,
			id: documentId,
			documentId: documentId,
			url: `${leveeUrl.httpUrl}/${leveeUrl.tenantId}/${documentId}`,
			endpoints: {
				deltaStorageUrl: `/deltas/${leveeUrl.tenantId}/${documentId}`,
				storageUrl: `${leveeUrl.httpUrl}/repos/${leveeUrl.tenantId}`,
			},
		};

		return new LeveeDocumentService(
			updatedUrl,
			this.tokenProvider,
			this.debug,
			this._serialization,
		);
	}
}
