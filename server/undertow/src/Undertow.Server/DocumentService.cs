using Undertow.Abstractions;
using Undertow.Protocol;

namespace Undertow.Server;

public enum CreateInitializedResult
{
    Created,
    AlreadyExists,
    InvalidInitialSummary,
}

/// <summary>
/// The REST surface's document/session facade over storage. Read paths answer
/// from storage only — they must never allocate a live session (Gleam's
/// `exists`/`sequence_number`/`since` have the same property).
/// </summary>
public sealed class DocumentService(IDocumentStore documents, IGitObjectStore gitObjects)
{
    public IGitObjectStore GitObjects => gitObjects;
    public IDocumentStore Documents => documents;

    public ValueTask<bool> ExistsAsync(string topic, CancellationToken ct = default) =>
        documents.StoredDocumentExistsAsync(topic, ct);

    public async ValueTask<long> SequenceNumberAsync(string topic, CancellationToken ct = default) =>
        (await documents.LoadOrSynthesizeCheckpointAsync(topic, ct)).SequenceNumber;

    public ValueTask<IReadOnlyList<OpRecord>> SinceAsync(string topic, long fromExclusive, CancellationToken ct = default) =>
        documents.GetOpsAsync(topic, fromExclusive, null, ct);

    public async ValueTask<(string Handle, long SequenceNumber)> SummaryAsync(string topic, CancellationToken ct = default)
    {
        var summary = await documents.GetSummaryAsync(topic, ct);
        return summary is null ? ("", 0) : (summary.Handle, summary.SequenceNumber);
    }

    /// <summary>
    /// Create a document, persisting the initial-summary object graph when the
    /// body carries one. Write order matches Gleam: objects → document row →
    /// summary pointer; the caller publishes the mirroring ref afterwards, so a
    /// crash can only leave the ref lagging.
    /// </summary>
    public async ValueTask<CreateInitializedResult> CreateInitializedAsync(
        string topic, string tenant, string body, long nowSeconds, CancellationToken ct = default)
    {
        if (await documents.StoredDocumentExistsAsync(topic, ct))
            return CreateInitializedResult.AlreadyExists;

        var plan = InitialSummaryBoundary.plan(body, nowSeconds, sha =>
            gitObjects.GetObjectAsync(tenant, sha, ct).AsTask().GetAwaiter().GetResult() is not null);

        switch (plan.Status)
        {
            case InitialSummaryStatus.Invalid:
                return CreateInitializedResult.InvalidInitialSummary;

            case InitialSummaryStatus.NoSummary:
                await documents.CreateDocumentAsync(topic, nowSeconds, ct);
                return CreateInitializedResult.Created;

            default:
                foreach (var (sha, objectBody) in plan.Objects)
                    await gitObjects.PutObjectAsync(tenant, sha, objectBody, ct);
                await documents.CreateDocumentAsync(topic, nowSeconds, ct);
                await documents.PutSummaryAsync(topic, new SummaryRecord(plan.CommitSha, plan.SequenceNumber), ct);
                return CreateInitializedResult.Created;
        }
    }

    /// <summary>The ref a document's latest summary commit is published under.</summary>
    public static string SummaryRef(string documentId) => $"refs/heads/{documentId}";

    /// <summary>Publish the summary ref; always after the summary pointer.</summary>
    public ValueTask PublishSummaryRefAsync(string tenant, string documentId, string sha, CancellationToken ct = default) =>
        gitObjects.PutRefAsync(tenant, SummaryRef(documentId), sha, ct);
}
