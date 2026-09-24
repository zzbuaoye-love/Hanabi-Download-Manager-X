using System.Text.Json;

namespace Hanabi.NeoNSF;

/// <summary>
/// One unit of work. Every field is guarded by <see cref="TransferPlan.Sync"/>.
/// </summary>
internal sealed class Chunk
{
    public const long Unbounded = long.MaxValue;

    public Chunk(long start, long end, long downloaded)
    {
        Start = start;
        End = end;
        Downloaded = downloaded;
    }

    public long Start { get; }

    /// <summary>Inclusive. <see cref="Unbounded"/> when the length is unknown.</summary>
    public long End { get; set; }

    /// <summary>Bytes durably handed to the OS. Never counts buffered-but-unwritten data.</summary>
    public long Downloaded { get; set; }

    /// <summary>
    /// Bytes handed to a write that has not completed yet. Splitting must treat these as
    /// already spoken for, otherwise a split point could land inside an in-flight write
    /// and the same range would be fetched twice.
    /// </summary>
    public long Reserved { get; set; }

    public bool Claimed { get; set; }

    public long Length => End == Unbounded ? Unbounded : End - Start + 1;

    public bool IsComplete => End != Unbounded && Downloaded >= Length;

    /// <summary>Next byte offset to fetch, including bytes reserved by a pending write.</summary>
    public long Frontier => Start + Downloaded + Reserved;
}

/// <summary>
/// The chunk queue for a single transfer.
/// </summary>
/// <remarks>
/// Replaces fixed "one equal segment per connection" splitting. With static segments the
/// transfer cannot finish faster than its slowest connection, so one throttled or badly
/// routed peer holds the last few percent hostage. Here the file is cut into many small
/// chunks that lanes pull on demand, so a slow lane simply completes fewer of them, and
/// the residual tail is further cut down by splitting the busiest in-flight chunk once
/// the queue runs dry.
/// </remarks>
internal sealed class TransferPlan
{
    public const int CheckpointVersion = 2;

    private readonly Queue<Chunk> _pending = new();
    private readonly List<Chunk> _chunks = new();

    private TransferPlan(
        string url,
        string effectiveUrl,
        long totalBytes,
        string? entityTag,
        string? lastModified,
        bool chunked)
    {
        Url = url;
        EffectiveUrl = effectiveUrl;
        TotalBytes = totalBytes;
        EntityTag = entityTag;
        LastModified = lastModified;
        Chunked = chunked;
    }

    public object Sync { get; } = new();

    public string Url { get; }

    public string EffectiveUrl { get; set; }

    /// <summary>Zero when the server never told us the length.</summary>
    public long TotalBytes { get; set; }

    public string? EntityTag { get; }

    public string? LastModified { get; }

    public bool Chunked { get; }

    public int ChunkCount
    {
        get
        {
            lock (Sync)
            {
                return _chunks.Count;
            }
        }
    }

    /// <summary>
    /// Starts as a single chunk covering the whole file and subdivides on demand.
    /// </summary>
    /// <remarks>
    /// Pre-cutting the file is pure cost. Every chunk boundary is one more sequential
    /// request on some lane's connection, and against a real CDN over a high-latency path
    /// those round trips dominated: sixteen pre-cut chunks made a 72 MiB transfer slower
    /// than a single unsegmented stream even though only two or three lanes ever ran.
    /// Splitting produces exactly one extra request per lane that actually comes online,
    /// which is the minimum possible, and it places the boundary using live progress
    /// instead of a guess made before any byte moved.
    /// </remarks>
    public static TransferPlan CreateChunked(
        string url,
        string effectiveUrl,
        long totalBytes,
        string? entityTag,
        string? lastModified,
        long chunkSize)
    {
        var plan = new TransferPlan(url, effectiveUrl, totalBytes, entityTag, lastModified, true);
        // chunkSize is only honoured when the host asked for an explicit size.
        var stride = chunkSize > 0 && chunkSize < totalBytes ? chunkSize : totalBytes;
        for (var start = 0L; start < totalBytes; start += stride)
        {
            var end = Math.Min(totalBytes - 1, start + stride - 1);
            plan._chunks.Add(new Chunk(start, end, 0));
        }
        plan.RebuildPendingLocked();
        return plan;
    }

    public static TransferPlan CreateStream(
        string url,
        string effectiveUrl,
        long totalBytes,
        string? entityTag,
        string? lastModified)
    {
        var plan = new TransferPlan(url, effectiveUrl, totalBytes, entityTag, lastModified, false);
        plan._chunks.Add(new Chunk(0, totalBytes > 0 ? totalBytes - 1 : Chunk.Unbounded, 0));
        plan.RebuildPendingLocked();
        return plan;
    }

    /// <summary>Smallest slice worth a dedicated request.</summary>
    public const long MinimumChunkSize = 4L * 1024 * 1024;

    /// <summary>
    /// Roughly two chunks per lane, then let work stealing do the rest.
    /// </summary>
    /// <remarks>
    /// Cutting finer than this is actively harmful on two counts, both measured against
    /// a real CDN. Every extra chunk is another sequential request on the lane's
    /// connection, so a 72 MiB file at eight chunks per lane cost 64 round trips instead
    /// of 16. Worse, chunks smaller than twice the split threshold make
    /// <see cref="TrySplitBusiest"/> a no-op, which silently disabled the one mechanism
    /// that rescues a stalled lane; transfers that hit a bad edge went from 3 s to 18 s
    /// with no way to recover. Large initial chunks keep splitting available for the
    /// whole transfer, and splitting — not pre-cutting — is what balances the lanes.
    /// </remarks>
    public static long ResolveChunkSize(long totalBytes, int lanes, long requested)
    {
        const long maximum = 64L * 1024 * 1024;
        if (requested > 0)
        {
            return Math.Clamp(requested, 64 * 1024, Math.Max(MinimumChunkSize, maximum * 4));
        }
        if (totalBytes <= 0)
        {
            return MinimumChunkSize;
        }
        var target = totalBytes / Math.Max(1, lanes * 2);
        return Math.Clamp(target, MinimumChunkSize, maximum);
    }

    public Chunk? TryTake()
    {
        lock (Sync)
        {
            while (_pending.Count > 0)
            {
                var chunk = _pending.Dequeue();
                if (chunk.IsComplete)
                {
                    continue;
                }
                chunk.Claimed = true;
                return chunk;
            }
            return null;
        }
    }

    public void Unclaim(Chunk chunk, bool requeue)
    {
        lock (Sync)
        {
            chunk.Claimed = false;
            if (requeue && !chunk.IsComplete)
            {
                _pending.Enqueue(chunk);
            }
        }
    }

    /// <summary>
    /// Cuts the tail off whichever in-flight chunk has the most work left and returns it
    /// as a new claimable chunk, or null when nothing is worth splitting.
    /// </summary>
    public Chunk? TrySplitBusiest(long minimumRemainder)
    {
        lock (Sync)
        {
            Chunk? victim = null;
            var best = 0L;
            foreach (var chunk in _chunks)
            {
                if (!chunk.Claimed || chunk.End == Chunk.Unbounded)
                {
                    continue;
                }
                var remaining = chunk.End - chunk.Frontier + 1;
                if (remaining > best)
                {
                    best = remaining;
                    victim = chunk;
                }
            }

            // Both halves must stay worth a round trip.
            if (victim is null || best < minimumRemainder * 2)
            {
                return null;
            }

            var oldEnd = victim.End;
            var splitPoint = victim.Frontier + Math.Max(minimumRemainder, best / 2);
            if (splitPoint <= victim.Frontier || splitPoint > oldEnd)
            {
                return null;
            }

            victim.End = splitPoint - 1;
            var tail = new Chunk(splitPoint, oldEnd, 0) { Claimed = true };
            _chunks.Add(tail);
            return tail;
        }
    }

    /// <summary>
    /// Clamps a pending write to the chunk's current end and reserves it. Returns the
    /// number of bytes the caller may write; zero means the chunk was split out from
    /// under it and is already finished.
    /// </summary>
    public int Reserve(Chunk chunk, long writeOffset, int available)
    {
        lock (Sync)
        {
            if (chunk.End == Chunk.Unbounded)
            {
                chunk.Reserved = available;
                return available;
            }
            var allowed = chunk.End - writeOffset + 1;
            if (allowed <= 0)
            {
                chunk.Reserved = 0;
                return 0;
            }
            var granted = (int)Math.Min(available, allowed);
            chunk.Reserved = granted;
            return granted;
        }
    }

    public void Commit(Chunk chunk, int written)
    {
        lock (Sync)
        {
            chunk.Downloaded += written;
            chunk.Reserved = 0;
        }
    }

    public void ReleaseReservation(Chunk chunk)
    {
        lock (Sync)
        {
            chunk.Reserved = 0;
        }
    }

    public long ChunkEnd(Chunk chunk)
    {
        lock (Sync)
        {
            return chunk.End;
        }
    }

    public long ChunkFrontier(Chunk chunk)
    {
        lock (Sync)
        {
            return chunk.Start + chunk.Downloaded;
        }
    }

    public bool IsChunkComplete(Chunk chunk)
    {
        lock (Sync)
        {
            return chunk.IsComplete;
        }
    }

    public long DownloadedTotal()
    {
        lock (Sync)
        {
            var total = 0L;
            foreach (var chunk in _chunks)
            {
                total += chunk.Downloaded;
            }
            return total;
        }
    }

    public bool AllComplete()
    {
        lock (Sync)
        {
            if (_pending.Count > 0)
            {
                return false;
            }
            foreach (var chunk in _chunks)
            {
                if (!chunk.IsComplete)
                {
                    return false;
                }
            }
            return true;
        }
    }

    public void MarkStreamComplete(Chunk chunk, long finalLength)
    {
        lock (Sync)
        {
            if (chunk.End == Chunk.Unbounded)
            {
                chunk.End = finalLength > 0 ? finalLength - 1 : 0;
            }
            TotalBytes = finalLength;
        }
    }

    private void RebuildPendingLocked()
    {
        _pending.Clear();
        foreach (var chunk in _chunks)
        {
            chunk.Claimed = false;
            chunk.Reserved = 0;
            if (!chunk.IsComplete)
            {
                _pending.Enqueue(chunk);
            }
        }
    }

    public void RebuildPending()
    {
        lock (Sync)
        {
            RebuildPendingLocked();
        }
    }

    public async Task SaveAsync(string path, string tempPath, CancellationToken cancellationToken)
    {
        using var memory = new MemoryStream(4096);
        using (var writer = new Utf8JsonWriter(memory))
        {
            writer.WriteStartObject();
            writer.WriteNumber("version", CheckpointVersion);
            writer.WriteString("url", Url);
            writer.WriteString("effectiveUrl", EffectiveUrl);
            writer.WriteBoolean("chunked", Chunked);
            lock (Sync)
            {
                writer.WriteNumber("totalBytes", TotalBytes);
                if (!string.IsNullOrWhiteSpace(EntityTag))
                {
                    writer.WriteString("etag", EntityTag);
                }
                if (!string.IsNullOrWhiteSpace(LastModified))
                {
                    writer.WriteString("lastModified", LastModified);
                }
                writer.WriteStartArray("chunks");
                foreach (var chunk in _chunks)
                {
                    writer.WriteStartObject();
                    writer.WriteNumber("s", chunk.Start);
                    writer.WriteNumber("e", chunk.End == Chunk.Unbounded ? -1 : chunk.End);
                    writer.WriteNumber("d", chunk.Downloaded);
                    writer.WriteEndObject();
                }
                writer.WriteEndArray();
            }
            writer.WriteEndObject();
            writer.Flush();
        }

        await using (var stream = new FileStream(
            tempPath,
            FileMode.Create,
            FileAccess.Write,
            FileShare.None,
            64 * 1024,
            FileOptions.Asynchronous))
        {
            memory.Position = 0;
            await memory.CopyToAsync(stream, cancellationToken).ConfigureAwait(false);
            await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
        }
        File.Move(tempPath, path, overwrite: true);
    }

    public static async Task<TransferPlan?> TryLoadAsync(string path, CancellationToken cancellationToken)
    {
        if (!File.Exists(path))
        {
            return null;
        }
        try
        {
            await using var stream = new FileStream(
                path,
                FileMode.Open,
                FileAccess.Read,
                FileShare.Read,
                64 * 1024,
                FileOptions.Asynchronous | FileOptions.SequentialScan);
            using var document = await JsonDocument
                .ParseAsync(stream, cancellationToken: cancellationToken)
                .ConfigureAwait(false);
            var root = document.RootElement;

            var url = root.TryGetProperty("url", out var urlNode)
                ? urlNode.GetString() ?? string.Empty
                : string.Empty;
            var effectiveUrl = root.TryGetProperty("effectiveUrl", out var effectiveNode)
                ? effectiveNode.GetString() ?? url
                : url;
            var totalBytes = root.TryGetProperty("totalBytes", out var totalNode)
                ? totalNode.GetInt64()
                : 0;
            var entityTag = root.TryGetProperty("etag", out var tagNode) ? tagNode.GetString() : null;
            var lastModified = root.TryGetProperty("lastModified", out var modifiedNode)
                ? modifiedNode.GetString()
                : null;
            var chunked = !root.TryGetProperty("chunked", out var chunkedNode) || chunkedNode.GetBoolean();

            var plan = new TransferPlan(url, effectiveUrl, totalBytes, entityTag, lastModified, chunked);

            if (root.TryGetProperty("chunks", out var chunkNodes))
            {
                foreach (var node in chunkNodes.EnumerateArray())
                {
                    var end = node.GetProperty("e").GetInt64();
                    plan._chunks.Add(new Chunk(
                        node.GetProperty("s").GetInt64(),
                        end < 0 ? Chunk.Unbounded : end,
                        node.GetProperty("d").GetInt64()));
                }
            }
            else if (root.TryGetProperty("segments", out var segmentNodes))
            {
                // Checkpoint written by the pre-1.0 engine.
                foreach (var node in segmentNodes.EnumerateArray())
                {
                    plan._chunks.Add(new Chunk(
                        node.GetProperty("start").GetInt64(),
                        node.GetProperty("end").GetInt64(),
                        node.GetProperty("downloadedBytes").GetInt64()));
                }
            }

            if (plan._chunks.Count == 0)
            {
                return null;
            }

            plan.RebuildPendingLocked();
            return plan;
        }
        catch (JsonException)
        {
            return null;
        }
        catch (KeyNotFoundException)
        {
            return null;
        }
        catch (InvalidOperationException)
        {
            return null;
        }
        catch (IOException)
        {
            return null;
        }
    }

    /// <summary>
    /// Guards against a checkpoint describing a different resource than the one the
    /// server is serving now.
    /// </summary>
    public bool Matches(long totalBytes, string? entityTag, string? lastModified)
    {
        if (TotalBytes != totalBytes || totalBytes <= 0)
        {
            return false;
        }
        if (!string.IsNullOrWhiteSpace(EntityTag) || !string.IsNullOrWhiteSpace(entityTag))
        {
            return string.Equals(EntityTag, entityTag, StringComparison.Ordinal);
        }
        if (!string.IsNullOrWhiteSpace(LastModified) || !string.IsNullOrWhiteSpace(lastModified))
        {
            return string.Equals(LastModified, lastModified, StringComparison.Ordinal);
        }
        // No validator at all: resuming would be a coin flip on whether the bytes still
        // line up, so refuse and restart cleanly.
        return false;
    }
}
