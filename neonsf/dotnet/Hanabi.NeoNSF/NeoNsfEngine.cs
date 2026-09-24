using System.Buffers;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Globalization;
using System.Net;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using Microsoft.Win32.SafeHandles;

namespace Hanabi.NeoNSF;

internal sealed class NeoNsfEngine : IAsyncDisposable
{
    /// <summary>
    /// Payload is accumulated here before hitting the disk. At 64 KiB the previous engine
    /// issued roughly 2000 async writes per second per lane at gigabit speeds, all at
    /// scattered offsets.
    /// </summary>
    private const int WriteBufferSize = 512 * 1024;

    /// <summary>
    /// Both halves of a split must stay at least this large. Chunks are sized at least
    /// twice this (see <see cref="TransferPlan.MinimumChunkSize"/>) so splitting stays
    /// possible for the entire transfer.
    /// </summary>
    private const long MinimumSplitRemainder = 1L * 1024 * 1024;

    private const long MinimumLaneBytesPerSecond = 2048;

    /// <summary>
    /// Kept short deliberately. At twenty seconds a stalled lane outlived most transfers
    /// entirely, so the breaker never fired on exactly the runs that needed it.
    /// </summary>
    private const double LaneStallWindowSeconds = 6;
    private const int IdleLanePollMilliseconds = 200;

    /// <summary>Time the first lane gets to leave slow start before it sets the yardstick.</summary>
    private static readonly TimeSpan LaneWarmupDelay = TimeSpan.FromMilliseconds(1500);

    /// <summary>How long a newly enabled lane gets before its effect is judged.</summary>
    private static readonly TimeSpan LaneRampInterval = TimeSpan.FromMilliseconds(1200);

    /// <summary>Throughput gain a new lane must produce to justify keeping it.</summary>
    private const double LaneRampGain = 1.15;

    /// <summary>
    /// How long a newly enabled lane gets to deliver its first byte before it is judged a
    /// dud. Covers DNS + TCP + TLS + request on a bad international path.
    /// </summary>
    private static readonly TimeSpan LaneFirstByteTimeout = TimeSpan.FromSeconds(6);

    /// <summary>Pause before re-probing after a lane failed to pay for itself.</summary>
    private static readonly TimeSpan LaneReprobeDelay = TimeSpan.FromSeconds(6);

    /// <summary>Consecutive failed probes before the governor stops for good.</summary>
    private const int MaxLaneRetreats = 2;

    /// <summary>Do not bother adding lanes when this little work remains.</summary>
    private const long MinimumRemainingForNewLane = 4L * 1024 * 1024;

    private static readonly TimeSpan ProgressInterval = TimeSpan.FromMilliseconds(250);
    private static readonly TimeSpan CheckpointInterval = TimeSpan.FromSeconds(1);

    private readonly ProtocolWriter _writer;
    private readonly HttpClientPool _clients = new();
    private readonly ConcurrentDictionary<string, TransferControl> _tasks = new();
    private readonly ConcurrencyGate _gate;
    private readonly RateLimiter _limiter = new(0);
    private readonly CancellationTokenSource _shutdown = new();
    private readonly Task _progressPump;
    private readonly Task _checkpointPump;

    public NeoNsfEngine(ProtocolWriter writer, int maxConcurrentTransfers = 5)
    {
        _writer = writer;
        _gate = new ConcurrencyGate(maxConcurrentTransfers);
        _progressPump = Task.Run(ProgressLoopAsync);
        _checkpointPump = Task.Run(CheckpointLoopAsync);
    }

    // ---------------------------------------------------------------- commands

    public bool Enqueue(TransferSpec spec, out string? error)
    {
        error = null;
        var control = new TransferControl(spec);
        if (!_tasks.TryAdd(spec.TaskId, control))
        {
            // Idempotent: the host retries enqueue when it cannot tell whether the
            // engine still owns a task, and a hard failure there surfaces as a raw
            // error in the UI.
            if (_tasks.TryGetValue(spec.TaskId, out var existing) &&
                existing.State == TransferState.Paused)
            {
                _ = ResumeAsync(spec.TaskId);
                return true;
            }
            error = "A task with the same ID already exists.";
            return false;
        }

        EmitState("accepted", spec.TaskId);
        lock (control.Sync)
        {
            control.Execution = Task.Run(() => RunTransferAsync(control));
        }
        return true;
    }

    public bool Pause(string taskId) => Stop(taskId, StopMode.Pause);

    public bool Cancel(string taskId, bool deletePartial) =>
        Stop(taskId, deletePartial ? StopMode.CancelAndDelete : StopMode.Cancel);

    public void Configure(int? maxConcurrentTransfers, long? maxBytesPerSecond)
    {
        if (maxConcurrentTransfers is { } limit)
        {
            _gate.SetLimit(limit);
        }
        if (maxBytesPerSecond is { } rate)
        {
            _limiter.SetRate(rate);
        }
    }

    public async Task<bool> ResumeAsync(string taskId)
    {
        if (!_tasks.TryGetValue(taskId, out var control))
        {
            return false;
        }

        Task? previous;
        lock (control.Sync)
        {
            if (control.State != TransferState.Paused)
            {
                return false;
            }
            control.State = TransferState.Pending;
            previous = control.Execution;
        }

        // The previous run must be fully unwound before a new one starts, otherwise two
        // executions briefly share the same partial file and the stale one emits a
        // "paused" event after the new one has already emitted "started".
        if (previous is not null)
        {
            try
            {
                await previous.ConfigureAwait(false);
            }
            catch (Exception)
            {
            }
        }

        lock (control.Sync)
        {
            control.Cancellation.Dispose();
            control.Cancellation = new CancellationTokenSource();
            control.StopMode = StopMode.None;
            control.ResetSpeedSamples();
            control.Execution = Task.Run(() => RunTransferAsync(control));
        }
        return true;
    }

    private bool Stop(string taskId, StopMode mode)
    {
        if (!_tasks.TryGetValue(taskId, out var control))
        {
            return false;
        }

        lock (control.Sync)
        {
            if (control.State == TransferState.Paused)
            {
                if (mode == StopMode.Pause)
                {
                    return true;
                }
                if (mode == StopMode.CancelAndDelete)
                {
                    DeleteWorkArtifacts(control.Spec);
                    TryDelete(control.Spec.FilePath);
                }
                control.StopMode = mode;
                control.State = TransferState.Cancelled;
                RemoveTerminalTask(control);
                EmitState("cancelled", control.Spec.TaskId);
                return true;
            }

            control.StopMode = mode;
            try
            {
                control.Cancellation.Cancel();
            }
            catch (ObjectDisposedException)
            {
            }
        }
        return true;
    }

    // ---------------------------------------------------------------- lifecycle

    private async Task RunTransferAsync(TransferControl control)
    {
        var spec = control.Spec;
        var token = control.Cancellation.Token;
        var holdsSlot = false;
        Exception? lastError = null;

        try
        {
            if (!_gate.TryEnter())
            {
                control.State = TransferState.Queued;
                EmitState("queued", spec.TaskId);
                await _gate.EnterAsync(token).ConfigureAwait(false);
            }
            holdsSlot = true;

            control.State = TransferState.Running;
            control.StartedAt ??= DateTimeOffset.UtcNow;
            EmitState("started", spec.TaskId);

            for (var attempt = 0; ; attempt++)
            {
                control.BeginAttempt();
                try
                {
                    await ExecuteAsync(control, token).ConfigureAwait(false);
                    return;
                }
                catch (OperationCanceledException) when (token.IsCancellationRequested)
                {
                    throw;
                }
                catch (Exception error)
                {
                    lastError = error;
                    if (RequiresCleanRestart(error))
                    {
                        // The bytes on disk can no longer be trusted: the resource
                        // changed, the server stopped honouring ranges, or it answered
                        // with a range we did not ask for. ForceStreamMode (set by the
                        // lane) survives this and makes the replan pick a single stream.
                        DeleteWorkArtifacts(spec);
                        control.ResetProgress();
                    }
                    else if (IsPermanent(error))
                    {
                        break;
                    }
                    if (attempt >= spec.MaxRetries)
                    {
                        break;
                    }
                }
                finally
                {
                    control.EndAttempt();
                }

                EmitRetry(spec.TaskId, attempt + 1, lastError!.Message);
                await Task.Delay(BackoffFor(attempt), token).ConfigureAwait(false);
            }

            control.State = TransferState.Failed;
            RemoveTerminalTask(control);
            EmitFailure(spec.TaskId, lastError?.Message ?? "Unknown transfer failure.");
        }
        catch (OperationCanceledException)
        {
            await FinishCancellationAsync(control).ConfigureAwait(false);
        }
        catch (Exception error)
        {
            control.State = TransferState.Failed;
            RemoveTerminalTask(control);
            EmitFailure(spec.TaskId, error.Message);
        }
        finally
        {
            if (holdsSlot)
            {
                _gate.Release();
            }
        }
    }

    private async Task ExecuteAsync(TransferControl control, CancellationToken cancellationToken)
    {
        var spec = control.Spec;
        EnsureParentDirectory(spec.FilePath);

        var hasCheckpoint = File.Exists(spec.CheckpointPath) && File.Exists(spec.PartialPath);
        if (!hasCheckpoint)
        {
            // An orphaned .partial without state (or the reverse) cannot be joined safely.
            DeleteWorkArtifacts(spec);
        }

        using var probe = await ProbeAsync(control, wantFullBody: !hasCheckpoint, cancellationToken)
            .ConfigureAwait(false);

        TransferPlan plan;
        var lanes = Math.Max(1, spec.MaxConnections);

        if (hasCheckpoint)
        {
            var restored = await TransferPlan.TryLoadAsync(spec.CheckpointPath, cancellationToken)
                .ConfigureAwait(false);
            var partialLength = new FileInfo(spec.PartialPath).Length;
            var usable = restored is not null &&
                         string.Equals(restored.Url, spec.Url, StringComparison.Ordinal) &&
                         restored.Matches(probe.TotalBytes, probe.ETag, probe.LastModified) &&
                         (!restored.Chunked || partialLength == restored.TotalBytes);
            if (!usable)
            {
                throw new RestartFromScratchException(
                    "RESUME_STATE_INVALID: the stored checkpoint no longer matches the remote resource.");
            }
            plan = restored!;
            plan.EffectiveUrl = probe.EffectiveUrl;
            plan.RebuildPending();
        }
        else
        {
            var chunked = probe.SupportsRanges &&
                          !control.ForceStreamMode &&
                          lanes > 1 &&
                          probe.TotalBytes >= spec.ParallelThresholdBytes;
            if (chunked)
            {
                plan = TransferPlan.CreateChunked(
                    spec.Url,
                    probe.EffectiveUrl,
                    probe.TotalBytes,
                    probe.ETag,
                    probe.LastModified,
                    spec.ChunkSizeBytes);
                CreatePreallocated(spec.PartialPath, probe.TotalBytes);
            }
            else
            {
                plan = TransferPlan.CreateStream(
                    spec.Url,
                    probe.EffectiveUrl,
                    probe.TotalBytes,
                    probe.ETag,
                    probe.LastModified);
                CreateEmpty(spec.PartialPath);
            }
            await plan.SaveAsync(spec.CheckpointPath, spec.CheckpointTempPath, cancellationToken)
                .ConfigureAwait(false);
        }

        control.Plan = plan;
        control.TotalBytes = plan.TotalBytes;
        Interlocked.Exchange(ref control.DownloadedBytes, plan.DownloadedTotal());
        control.ResetSpeedSamples();

        // Not bounded by the current chunk count any more: chunks are produced by
        // splitting as lanes come online, so the ceiling is just the configured maximum.
        var laneCount = plan.Chunked ? Math.Max(1, lanes) : 1;
        control.ConnectionCount = laneCount;

        EmitHeaders(
            spec.TaskId,
            plan.TotalBytes,
            probe.StatusCode,
            probe.HttpVersion,
            probe.SupportsRanges,
            laneCount,
            plan.Chunked ? "parallel_range" : "direct",
            plan.EntityTag,
            plan.LastModified);

        using (var fatal = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken))
        using (var handle = File.OpenHandle(
            spec.PartialPath,
            FileMode.Open,
            FileAccess.Write,
            FileShare.Read,
            FileOptions.Asynchronous |
                (plan.Chunked ? FileOptions.RandomAccess : FileOptions.SequentialScan)))
        {
            var context = new TransferContext(control, plan, handle, fatal)
            {
                LaneFirstByteTicks = new long[laneCount],
            };

            // The probe response is already streaming from byte 0. Handing it to lane 0
            // as its first chunk removes an entire request/response round trip from the
            // critical path, which is most of the latency for a small file.
            Chunk? seedChunk = null;
            Stream? seedBody = null;
            if (!hasCheckpoint && probe.HasBody)
            {
                seedChunk = plan.TryTake();
                if (seedChunk is not null && plan.ChunkFrontier(seedChunk) == 0)
                {
                    seedBody = probe.TakeBody();
                }
                else if (seedChunk is not null)
                {
                    plan.Unclaim(seedChunk, requeue: true);
                    seedChunk = null;
                }
            }

            // Lanes are all started, but only the first is enabled. The governor raises
            // TargetLanes while extra connections keep paying for themselves. Measured
            // against real CDNs, a fixed lane count is wrong in both directions: on a
            // link a single connection cannot saturate, eight lanes were 2.5x faster,
            // while on a congested proxy path the same eight lanes were up to 7x slower
            // than one. Only measurement can tell those apart.
            Volatile.Write(ref context.TargetLanes, 1);
            control.ConnectionCount = 1;

            var laneTasks = new List<Task>(laneCount);
            for (var index = 0; index < laneCount; index++)
            {
                var lane = index;
                var chunk = lane == 0 ? seedChunk : null;
                var body = lane == 0 ? seedBody : null;
                laneTasks.Add(Task.Run(() => RunLaneAsync(context, lane, chunk, body, fatal.Token)));
            }

            using var ramp = CancellationTokenSource.CreateLinkedTokenSource(fatal.Token);
            var governor = laneCount > 1
                ? Task.Run(() => RunLaneGovernorAsync(context, laneCount, ramp.Token))
                : Task.CompletedTask;

            try
            {
                await Task.WhenAll(laneTasks).ConfigureAwait(false);
            }
            finally
            {
                ramp.Cancel();
                try
                {
                    await governor.ConfigureAwait(false);
                }
                catch (Exception)
                {
                }
            }

            cancellationToken.ThrowIfCancellationRequested();
            if (context.Error is { } laneError)
            {
                throw laneError;
            }
        }

        await FinalizeAsync(control, plan, cancellationToken).ConfigureAwait(false);
    }

    // ---------------------------------------------------------------- probing

    /// <summary>
    /// A single ranged GET replaces the old HEAD preflight.
    /// </summary>
    /// <remarks>
    /// HEAD cost a full round trip before any payload could flow, and it is answered
    /// badly or not at all by a lot of CDNs and object stores — a blackholed HEAD used to
    /// burn the whole read timeout before the engine fell back to a plain GET, so a
    /// 200 KiB file could take 30 seconds. "Range: bytes=0-" answers every question the
    /// planner has (length, range support, validators, final URL after redirects) and,
    /// unlike HEAD, the response body is the download itself.
    /// </remarks>
    private async Task<ProbeResult> ProbeAsync(
        TransferControl control,
        bool wantFullBody,
        CancellationToken cancellationToken)
    {
        var spec = control.Spec;
        using var request = new HttpRequestMessage(HttpMethod.Get, spec.Url);
        ConfigureVersion(request, spec.HttpVersionPolicy);
        ApplyRequestHeaders(request, spec);
        request.Headers.Range = wantFullBody
            ? new RangeHeaderValue(0, null)
            : new RangeHeaderValue(0, 0);

        var client = _clients.Get(spec, 0);
        var response = await SendAsync(client, request, spec.HeaderTimeoutSeconds, cancellationToken)
            .ConfigureAwait(false);

        try
        {
            var effectiveUrl = response.RequestMessage?.RequestUri?.ToString() ?? spec.Url;
            var entityTag = response.Headers.ETag?.ToString();
            var lastModified = response.Content.Headers.LastModified?.ToString(
                "R",
                CultureInfo.InvariantCulture);

            if (response.StatusCode == HttpStatusCode.RequestedRangeNotSatisfiable)
            {
                // Also what a zero byte resource answers to "bytes=0-". Fall through to a
                // plain unranged GET, which handles both that and servers that simply
                // dislike open ended ranges.
                var declared = response.Content.Headers.ContentRange?.Length ?? 0;
                response.Dispose();
                return new ProbeResult(
                    null,
                    null,
                    declared,
                    false,
                    entityTag,
                    lastModified,
                    effectiveUrl,
                    HttpVersion.Version11,
                    HttpStatusCode.OK);
            }

            if ((int)response.StatusCode >= 400)
            {
                throw new HttpRequestException(
                    $"HTTP {(int)response.StatusCode} {response.ReasonPhrase}".TrimEnd(),
                    null,
                    response.StatusCode);
            }

            long totalBytes;
            bool supportsRanges;
            if (response.StatusCode == HttpStatusCode.PartialContent)
            {
                supportsRanges = true;
                totalBytes = response.Content.Headers.ContentRange?.Length ?? 0;
                if (totalBytes <= 0)
                {
                    totalBytes = spec.ExpectedSize ?? 0;
                }
            }
            else
            {
                // The server answered the whole entity. It may still honour ranges on a
                // subsequent request; Accept-Ranges is the only signal available, and a
                // chunk request that comes back 200 falls back cleanly anyway.
                totalBytes = response.Content.Headers.ContentLength ?? spec.ExpectedSize ?? 0;
                supportsRanges = response.Headers.AcceptRanges.Contains("bytes");
            }

            if (!wantFullBody)
            {
                // A one byte validation probe. Nothing to reuse, so release the
                // connection back to the pool immediately.
                var version = response.Version;
                var status = response.StatusCode;
                response.Dispose();
                return new ProbeResult(
                    null,
                    null,
                    totalBytes,
                    supportsRanges,
                    entityTag,
                    lastModified,
                    effectiveUrl,
                    version,
                    status);
            }

            var body = await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
            return new ProbeResult(
                response,
                body,
                totalBytes,
                supportsRanges,
                entityTag,
                lastModified,
                effectiveUrl,
                response.Version,
                response.StatusCode);
        }
        catch (Exception)
        {
            response.Dispose();
            throw;
        }
    }

    // ---------------------------------------------------------------- lanes

    private async Task RunLaneAsync(
        TransferContext context,
        int lane,
        Chunk? seedChunk,
        Stream? seedBody,
        CancellationToken cancellationToken)
    {
        var plan = context.Plan;
        var chunk = seedChunk;
        var body = seedBody;

        try
        {
            while (!cancellationToken.IsCancellationRequested)
            {
                if (lane >= Volatile.Read(ref context.TargetLanes))
                {
                    // Not enabled by the governor yet, or retired because it did not earn
                    // its keep. Lane 0 is never in this state.
                    if (Volatile.Read(ref context.BusyLanes) == 0 && plan.AllComplete())
                    {
                        break;
                    }
                    await Task.Delay(IdleLanePollMilliseconds, cancellationToken)
                        .ConfigureAwait(false);
                    continue;
                }

                var current = chunk;
                chunk = null;

                if (current is null)
                {
                    // Queue drained. Steal the tail of whichever lane still has the most
                    // work left; this is what stops one slow connection from owning the
                    // last few percent of the file.
                    current = plan.TryTake() ?? plan.TrySplitBusiest(MinimumSplitRemainder);
                }

                if (current is null)
                {
                    if (Volatile.Read(ref context.BusyLanes) == 0)
                    {
                        break;
                    }
                    await Task.Delay(IdleLanePollMilliseconds, cancellationToken).ConfigureAwait(false);
                    continue;
                }

                var seed = body;
                body = null;
                Interlocked.Increment(ref context.BusyLanes);
                try
                {
                    await DownloadChunkAsync(context, lane, current, seed, cancellationToken)
                        .ConfigureAwait(false);
                }
                finally
                {
                    Interlocked.Decrement(ref context.BusyLanes);
                    plan.Unclaim(current, requeue: false);
                }
            }
        }
        catch (OperationCanceledException)
        {
            if (!cancellationToken.IsCancellationRequested)
            {
                context.ReportError(new TimeoutException("Lane cancelled unexpectedly."), isFatal: false);
            }
        }
        catch (Exception error)
        {
            context.ReportError(error, isFatal: error is FatalTransferException);
        }
        finally
        {
            body?.Dispose();
        }
    }

    /// <summary>
    /// Hill-climbs the lane count: add one, check whether aggregate throughput actually
    /// improved, and give the lane back when it did not.
    /// </summary>
    /// <remarks>
    /// Extra connections are not free. They cost a TLS handshake each, they multiply
    /// per-connection congestion control, and on a saturated or proxied path they simply
    /// divide the same bandwidth into more contending streams. Starting at one lane and
    /// escalating only on measured evidence keeps the win where parallelism helps without
    /// paying for it where it does not.
    ///
    /// Two details are load-bearing, both learned on real CDNs. The baseline is
    /// re-measured immediately before every step, because judging lane N against a rate
    /// captured while lane 0 was still in slow start walks the count in whichever
    /// direction the noise pointed. And the judgment window opens only once the new lane
    /// has delivered its first byte: on a 200 ms path, DNS + TLS + slow start consumed
    /// the whole fixed window, so lanes were retired before they had sent anything and
    /// the governor quit exactly where parallelism pays the most.
    /// </remarks>
    private async Task RunLaneGovernorAsync(
        TransferContext context,
        int maxLanes,
        CancellationToken cancellationToken)
    {
        var control = context.Control;
        var retreats = 0;

        async Task<double> MeasureRateAsync()
        {
            var startBytes = Interlocked.Read(ref control.DownloadedBytes);
            var startTicks = Stopwatch.GetTimestamp();
            await Task.Delay(LaneRampInterval, cancellationToken).ConfigureAwait(false);
            var elapsed = (Stopwatch.GetTimestamp() - startTicks) / (double)Stopwatch.Frequency;
            var delta = Interlocked.Read(ref control.DownloadedBytes) - startBytes;
            return elapsed > 0 ? delta / elapsed : 0;
        }

        bool WorthAnotherLane()
        {
            var total = Volatile.Read(ref control.TotalBytes);
            if (total <= 0)
            {
                return false;
            }
            var remaining = total - Interlocked.Read(ref control.DownloadedBytes);
            return remaining >= MinimumRemainingForNewLane && !context.Plan.AllComplete();
        }

        try
        {
            await Task.Delay(LaneWarmupDelay, cancellationToken).ConfigureAwait(false);

            while (!cancellationToken.IsCancellationRequested && WorthAnotherLane())
            {
                var target = Volatile.Read(ref context.TargetLanes);
                if (target >= maxLanes)
                {
                    return;
                }

                var baseline = await MeasureRateAsync().ConfigureAwait(false);
                if (baseline <= 0 || !WorthAnotherLane())
                {
                    continue;
                }

                var lane = target;
                var slots = context.LaneFirstByteTicks;
                if (lane < slots.Length)
                {
                    Volatile.Write(ref slots[lane], 0);
                }
                Volatile.Write(ref context.TargetLanes, target + 1);
                control.ConnectionCount = target + 1;

                var streaming = await WaitForFirstByteAsync(context, lane, cancellationToken)
                    .ConfigureAwait(false);
                var rate = streaming ? await MeasureRateAsync().ConfigureAwait(false) : 0;

                if (rate >= baseline * LaneRampGain)
                {
                    retreats = 0;
                    continue;
                }

                Volatile.Write(ref context.TargetLanes, target);
                control.ConnectionCount = target;
                retreats++;
                if (retreats >= MaxLaneRetreats)
                {
                    return;
                }

                // Conditions change over a long transfer: a congested minute passes, a
                // throttled edge recovers. One delayed re-probe is a single spare
                // connection, and it is what rescues the transfer that started during
                // the bad minute.
                await Task.Delay(LaneReprobeDelay, cancellationToken).ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException)
        {
        }
    }

    private static async Task<bool> WaitForFirstByteAsync(
        TransferContext context,
        int lane,
        CancellationToken cancellationToken)
    {
        var slots = context.LaneFirstByteTicks;
        if (lane >= slots.Length)
        {
            return false;
        }
        var deadline = Stopwatch.GetTimestamp() +
                       (long)(LaneFirstByteTimeout.TotalSeconds * Stopwatch.Frequency);
        while (Stopwatch.GetTimestamp() < deadline)
        {
            if (Volatile.Read(ref slots[lane]) != 0)
            {
                return true;
            }
            if (context.Plan.AllComplete())
            {
                return false;
            }
            await Task.Delay(50, cancellationToken).ConfigureAwait(false);
        }
        return false;
    }

    private async Task DownloadChunkAsync(
        TransferContext context,
        int lane,
        Chunk chunk,
        Stream? seedBody,
        CancellationToken cancellationToken)
    {
        var spec = context.Control.Spec;
        var body = seedBody;
        HttpResponseMessage? response = null;

        for (var attempt = 0; ; attempt++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            try
            {
                if (body is null)
                {
                    (response, body) = await OpenChunkStreamAsync(context, lane, chunk, cancellationToken)
                        .ConfigureAwait(false);
                }
                await PumpAsync(context, lane, chunk, body, cancellationToken).ConfigureAwait(false);
                return;
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                throw;
            }
            catch (FatalTransferException)
            {
                throw;
            }
            catch (Exception error) when (attempt < spec.MaxSegmentRetries && !IsPermanent(error))
            {
                EmitSegmentRetry(spec.TaskId, lane, attempt + 1, error.Message);
                // Drop this lane's pooled socket so the retry re-resolves and usually
                // lands on a different edge instead of retrying the same bad path.
                _clients.RecycleLane(spec, lane);
                await Task.Delay(BackoffFor(attempt), cancellationToken).ConfigureAwait(false);
            }
            finally
            {
                body?.Dispose();
                body = null;
                response?.Dispose();
                response = null;
            }
        }
    }

    private async Task<(HttpResponseMessage Response, Stream Body)> OpenChunkStreamAsync(
        TransferContext context,
        int lane,
        Chunk chunk,
        CancellationToken cancellationToken)
    {
        var spec = context.Control.Spec;
        var plan = context.Plan;

        long start;
        long end;
        lock (plan.Sync)
        {
            start = chunk.Start + chunk.Downloaded;
            end = chunk.End;
        }

        using var request = new HttpRequestMessage(HttpMethod.Get, plan.EffectiveUrl);
        ConfigureVersion(request, spec.HttpVersionPolicy);
        ApplyRequestHeaders(request, spec);

        var ranged = start > 0 || end != Chunk.Unbounded;
        if (ranged)
        {
            request.Headers.Range = end == Chunk.Unbounded
                ? new RangeHeaderValue(start, null)
                : new RangeHeaderValue(start, end);
            ApplyIfRange(request, plan.EntityTag, plan.LastModified);
        }

        var client = _clients.Get(spec, lane);
        var response = await SendAsync(client, request, spec.HeaderTimeoutSeconds, cancellationToken)
            .ConfigureAwait(false);

        try
        {
            if ((int)response.StatusCode >= 400)
            {
                throw new HttpRequestException(
                    $"HTTP {(int)response.StatusCode} {response.ReasonPhrase}".TrimEnd(),
                    null,
                    response.StatusCode);
            }

            if (ranged && response.StatusCode == HttpStatusCode.OK)
            {
                if (start == 0 && !plan.Chunked)
                {
                    // Harmless: we wanted the whole entity anyway.
                }
                else
                {
                    context.Control.ForceStreamMode = true;
                    throw new RangeNotSupportedException(
                        "RANGE_NOT_SUPPORTED: the server ignored a range request mid-transfer.");
                }
            }

            if (response.StatusCode == HttpStatusCode.PartialContent)
            {
                var contentRange = response.Content.Headers.ContentRange;
                var boundedEnd = end == Chunk.Unbounded ? contentRange?.To : end;
                if (contentRange?.From != start ||
                    contentRange.To != boundedEnd ||
                    (plan.TotalBytes > 0 && contentRange.Length != plan.TotalBytes))
                {
                    throw new RangeValidationException(
                        $"RANGE_RESPONSE_INVALID: expected {start}-{(end == Chunk.Unbounded ? "" : end)}" +
                        $"/{plan.TotalBytes}, got {contentRange?.ToString() ?? "none"}.");
                }
            }

            if (!ValidatorMatches(
                    plan,
                    response.Headers.ETag?.ToString(),
                    response.Content.Headers.LastModified?.ToString("R", CultureInfo.InvariantCulture)))
            {
                throw new ValidatorChangedException(
                    "RESUME_VALIDATOR_CHANGED: the remote resource changed while downloading.");
            }

            var body = await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
            return (response, body);
        }
        catch (Exception)
        {
            response.Dispose();
            throw;
        }
    }

    /// <summary>Reads one chunk's stream into the target file.</summary>
    private async Task PumpAsync(
        TransferContext context,
        int lane,
        Chunk chunk,
        Stream body,
        CancellationToken cancellationToken)
    {
        var control = context.Control;
        var spec = control.Spec;
        var plan = context.Plan;

        var buffer = ArrayPool<byte>.Shared.Rent(WriteBufferSize);
        var filled = 0;
        var writeOffset = plan.ChunkFrontier(chunk);
        var truncated = false;

        var windowStart = Stopwatch.GetTimestamp();
        var windowBytes = 0L;

        using var readTimeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);

        async ValueTask<bool> FlushAsync()
        {
            if (filled == 0)
            {
                return true;
            }

            var granted = plan.Reserve(chunk, writeOffset, filled);
            if (granted <= 0)
            {
                plan.ReleaseReservation(chunk);
                filled = 0;
                return false;
            }

            try
            {
                await RandomAccess
                    .WriteAsync(context.Handle, buffer.AsMemory(0, granted), writeOffset, cancellationToken)
                    .ConfigureAwait(false);
            }
            catch (Exception)
            {
                plan.ReleaseReservation(chunk);
                throw;
            }

            plan.Commit(chunk, granted);
            writeOffset += granted;
            Interlocked.Add(ref control.DownloadedBytes, granted);
            control.MarkCheckpointDirty();
            windowBytes += granted;

            var surplus = filled - granted;
            filled = 0;
            // Another lane split this chunk while the buffer was filling; everything past
            // the new end now belongs to the tail chunk and is refetched there.
            return surplus == 0;
        }

        try
        {
            while (true)
            {
                var capacity = buffer.Length - filled;
                if (capacity == 0)
                {
                    if (!await FlushAsync().ConfigureAwait(false))
                    {
                        truncated = true;
                        break;
                    }
                    continue;
                }

                var budget = await _limiter.AcquireAsync(capacity, cancellationToken).ConfigureAwait(false);

                readTimeout.CancelAfter(TimeSpan.FromSeconds(spec.ReadTimeoutSeconds));
                int read;
                try
                {
                    read = await body.ReadAsync(buffer.AsMemory(filled, budget), readTimeout.Token)
                        .ConfigureAwait(false);
                }
                catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
                {
                    throw new TimeoutException(
                        $"No data received for {spec.ReadTimeoutSeconds}s.");
                }
                readTimeout.CancelAfter(Timeout.InfiniteTimeSpan);

                if (read > 0)
                {
                    context.MarkLaneStreaming(lane);
                }

                if (read == 0)
                {
                    break;
                }

                filled += read;
                Interlocked.Add(ref control.WireBytes, read);

                if (filled >= WriteBufferSize)
                {
                    if (!await FlushAsync().ConfigureAwait(false))
                    {
                        truncated = true;
                        break;
                    }
                }

                var elapsed = (Stopwatch.GetTimestamp() - windowStart) / (double)Stopwatch.Frequency;
                if (elapsed >= LaneStallWindowSeconds)
                {
                    ThrowIfLaneStalled(context, windowBytes / elapsed);
                    windowStart = Stopwatch.GetTimestamp();
                    windowBytes = 0;
                }
            }

            if (!truncated)
            {
                await FlushAsync().ConfigureAwait(false);
            }
        }
        finally
        {
            ArrayPool<byte>.Shared.Return(buffer);
        }

        if (truncated)
        {
            return;
        }

        lock (plan.Sync)
        {
            if (chunk.End == Chunk.Unbounded)
            {
                // Unknown length stream: EOF defines the size.
                chunk.End = writeOffset > 0 ? writeOffset - 1 : 0;
                plan.TotalBytes = writeOffset;
                control.TotalBytes = writeOffset;
                return;
            }
        }

        if (!plan.IsChunkComplete(chunk))
        {
            var frontier = plan.ChunkFrontier(chunk);
            var end = plan.ChunkEnd(chunk);
            throw new InvalidDataException(
                $"Connection closed early: {frontier - chunk.Start}/{end - chunk.Start + 1} bytes of the range.");
        }
    }

    private static void ThrowIfLaneStalled(TransferContext context, double laneBytesPerSecond)
    {
        var busy = Volatile.Read(ref context.BusyLanes);
        if (busy < 2)
        {
            // A single connection has nothing to be compared against, and a genuinely
            // slow link must never be killed.
            return;
        }
        var taskBps = context.Control.SmoothedBps;
        if (taskBps <= 0)
        {
            return;
        }
        var expected = taskBps / busy;
        var floor = Math.Max(MinimumLaneBytesPerSecond, expected / 8);
        if (laneBytesPerSecond < floor)
        {
            throw new LaneStalledException(
                $"LANE_STALLED: {laneBytesPerSecond:F0} B/s over {LaneStallWindowSeconds:F0}s " +
                $"against a {expected:F0} B/s per-lane average.");
        }
    }

    // ---------------------------------------------------------------- finish

    private async Task FinalizeAsync(
        TransferControl control,
        TransferPlan plan,
        CancellationToken cancellationToken)
    {
        var spec = control.Spec;
        var downloaded = plan.DownloadedTotal();
        var total = plan.TotalBytes;

        if (total > 0 && downloaded != total)
        {
            throw new InvalidDataException($"Incomplete transfer: {downloaded}/{total} bytes.");
        }

        if (spec.ExpectedSha256 is { } expected)
        {
            var actual = await ComputeSha256Async(spec.PartialPath, cancellationToken).ConfigureAwait(false);
            if (!string.Equals(actual, expected, StringComparison.Ordinal))
            {
                DeleteWorkArtifacts(spec);
                throw new ChecksumMismatchException(
                    $"CHECKSUM_MISMATCH: expected {expected}, computed {actual}.");
            }
        }

        File.Move(spec.PartialPath, spec.FilePath, overwrite: true);
        TryDelete(spec.CheckpointPath);
        TryDelete(spec.CheckpointTempPath);

        var final = total > 0 ? total : downloaded;
        Interlocked.Exchange(ref control.DownloadedBytes, final);
        control.TotalBytes = final;
        control.State = TransferState.Completed;
        RemoveTerminalTask(control);
        EmitCompleted(control);
    }

    private async Task FinishCancellationAsync(TransferControl control)
    {
        var mode = control.StopMode;
        var spec = control.Spec;

        if (mode == StopMode.Pause)
        {
            Interlocked.Exchange(ref control.CheckpointDirty, 0);
            await SaveCheckpointAsync(control).ConfigureAwait(false);
            control.State = TransferState.Paused;
            EmitState("paused", spec.TaskId);
            return;
        }

        if (mode == StopMode.CancelAndDelete)
        {
            DeleteWorkArtifacts(spec);
            TryDelete(spec.FilePath);
        }
        control.State = TransferState.Cancelled;
        RemoveTerminalTask(control);
        EmitState("cancelled", spec.TaskId);
    }

    // ---------------------------------------------------------------- pumps

    private async Task ProgressLoopAsync()
    {
        try
        {
            using var timer = new PeriodicTimer(ProgressInterval);
            while (await timer.WaitForNextTickAsync(_shutdown.Token).ConfigureAwait(false))
            {
                foreach (var control in _tasks.Values)
                {
                    if (control.State != TransferState.Running)
                    {
                        continue;
                    }
                    EmitProgress(control);
                }
            }
        }
        catch (OperationCanceledException)
        {
        }
    }

    private async Task CheckpointLoopAsync()
    {
        try
        {
            using var timer = new PeriodicTimer(CheckpointInterval);
            while (await timer.WaitForNextTickAsync(_shutdown.Token).ConfigureAwait(false))
            {
                foreach (var control in _tasks.Values)
                {
                    if (Interlocked.Exchange(ref control.CheckpointDirty, 0) == 0)
                    {
                        continue;
                    }
                    if (!await SaveCheckpointAsync(control).ConfigureAwait(false))
                    {
                        // Transient disk problem; try again on the next tick rather than
                        // losing the progress that was already made.
                        Interlocked.Exchange(ref control.CheckpointDirty, 1);
                    }
                }
            }
        }
        catch (OperationCanceledException)
        {
        }
    }

    // ---------------------------------------------------------------- helpers

    /// <summary>Writes the checkpoint under the task's gate. Never throws.</summary>
    private static async Task<bool> SaveCheckpointAsync(TransferControl control)
    {
        var plan = control.Plan;
        if (plan is null)
        {
            return true;
        }

        await control.CheckpointGate.WaitAsync().ConfigureAwait(false);
        try
        {
            await plan.SaveAsync(
                    control.Spec.CheckpointPath,
                    control.Spec.CheckpointTempPath,
                    CancellationToken.None)
                .ConfigureAwait(false);
            return true;
        }
        catch (IOException)
        {
            return false;
        }
        catch (UnauthorizedAccessException)
        {
            return false;
        }
        finally
        {
            control.CheckpointGate.Release();
        }
    }

    private static async Task<HttpResponseMessage> SendAsync(
        HttpClient client,
        HttpRequestMessage request,
        int headerTimeoutSeconds,
        CancellationToken cancellationToken)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(headerTimeoutSeconds));
        try
        {
            return await client
                .SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token)
                .ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            throw new TimeoutException(
                $"Timed out after {headerTimeoutSeconds}s waiting for response headers.");
        }
    }

    private static void ApplyRequestHeaders(HttpRequestMessage request, TransferSpec spec)
    {
        foreach (var header in spec.Headers)
        {
            if (IsReservedHeader(header.Key))
            {
                continue;
            }
            request.Headers.TryAddWithoutValidation(header.Key, header.Value);
        }
        // Range integrity depends on the bytes on the wire matching the bytes on disk, so
        // content coding is never negotiated.
        request.Headers.AcceptEncoding.Clear();
        request.Headers.AcceptEncoding.Add(new StringWithQualityHeaderValue("identity"));
    }

    private static bool IsReservedHeader(string name) =>
        name.Equals("content-length", StringComparison.OrdinalIgnoreCase) ||
        name.Equals("transfer-encoding", StringComparison.OrdinalIgnoreCase) ||
        name.Equals("connection", StringComparison.OrdinalIgnoreCase) ||
        name.Equals("keep-alive", StringComparison.OrdinalIgnoreCase) ||
        name.Equals("proxy-connection", StringComparison.OrdinalIgnoreCase) ||
        name.Equals("range", StringComparison.OrdinalIgnoreCase) ||
        name.Equals("if-range", StringComparison.OrdinalIgnoreCase) ||
        name.Equals("host", StringComparison.OrdinalIgnoreCase) ||
        name.Equals("expect", StringComparison.OrdinalIgnoreCase) ||
        name.Equals("te", StringComparison.OrdinalIgnoreCase) ||
        name.Equals("upgrade", StringComparison.OrdinalIgnoreCase) ||
        name.Equals("accept-encoding", StringComparison.OrdinalIgnoreCase);

    private static void ApplyIfRange(HttpRequestMessage request, string? entityTag, string? lastModified)
    {
        if (!string.IsNullOrWhiteSpace(entityTag) &&
            EntityTagHeaderValue.TryParse(entityTag, out var parsedEntityTag))
        {
            request.Headers.IfRange = new RangeConditionHeaderValue(parsedEntityTag);
            return;
        }
        // Invariant culture is mandatory: RFC 1123 dates do not parse under a zh-CN or
        // similar current culture, which silently disabled If-Range and turned every
        // resume into a full restart.
        if (!string.IsNullOrWhiteSpace(lastModified) &&
            DateTimeOffset.TryParse(
                lastModified,
                CultureInfo.InvariantCulture,
                DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal,
                out var parsedLastModified))
        {
            request.Headers.IfRange = new RangeConditionHeaderValue(parsedLastModified);
        }
    }

    private static bool ValidatorMatches(TransferPlan plan, string? entityTag, string? lastModified)
    {
        if (!string.IsNullOrWhiteSpace(plan.EntityTag))
        {
            // A weak validator legitimately changes representation between requests, so
            // only strong tags are treated as a hard mismatch.
            return string.IsNullOrWhiteSpace(entityTag) ||
                   string.Equals(plan.EntityTag, entityTag, StringComparison.Ordinal);
        }
        if (!string.IsNullOrWhiteSpace(plan.LastModified))
        {
            return string.IsNullOrWhiteSpace(lastModified) ||
                   string.Equals(plan.LastModified, lastModified, StringComparison.Ordinal);
        }
        return true;
    }

    private static void ConfigureVersion(HttpRequestMessage request, string policy)
    {
        switch (policy)
        {
            case "http1_only":
                request.Version = HttpVersion.Version11;
                request.VersionPolicy = HttpVersionPolicy.RequestVersionExact;
                break;
            case "http2_only":
                request.Version = HttpVersion.Version20;
                request.VersionPolicy = HttpVersionPolicy.RequestVersionExact;
                break;
            case "http3_only":
                request.Version = HttpVersion.Version30;
                request.VersionPolicy = HttpVersionPolicy.RequestVersionExact;
                break;
            default:
                request.Version = HttpVersion.Version20;
                request.VersionPolicy = HttpVersionPolicy.RequestVersionOrLower;
                break;
        }
    }

    /// <summary>
    /// Errors after which the partial file and checkpoint must be discarded before the
    /// transfer can be planned again.
    /// </summary>
    private static bool RequiresCleanRestart(Exception error) =>
        error is RestartFromScratchException
            or RangeNotSupportedException
            or ValidatorChangedException
            or RangeValidationException;

    private static bool IsPermanent(Exception error)
    {
        if (error is ChecksumMismatchException)
        {
            return true;
        }
        if (error is not HttpRequestException { StatusCode: { } status })
        {
            return false;
        }
        var code = (int)status;
        return code is >= 400 and < 500 &&
               status != HttpStatusCode.RequestTimeout &&
               status != HttpStatusCode.TooManyRequests;
    }

    private static TimeSpan BackoffFor(int attempt) =>
        TimeSpan.FromMilliseconds(Math.Min(5000, 250 * (1 << Math.Min(attempt, 5))));

    private static void EnsureParentDirectory(string filePath)
    {
        var parent = Path.GetDirectoryName(filePath);
        if (!string.IsNullOrWhiteSpace(parent))
        {
            Directory.CreateDirectory(parent);
        }
    }

    private static void CreatePreallocated(string path, long length)
    {
        using (new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.None))
        {
        }

        // Must happen while the file is still empty: NTFS would otherwise zero-fill the
        // gap between ValidDataLength and the first high offset write, which for parallel
        // ranges is very nearly the whole file.
        SparseFile.TryMarkSparse(path);

        using var target = new FileStream(path, FileMode.Open, FileAccess.Write, FileShare.None);
        target.SetLength(length);
    }

    private static void CreateEmpty(string path)
    {
        using var handle = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.None);
    }

    private static async Task<string> ComputeSha256Async(string path, CancellationToken cancellationToken)
    {
        await using var stream = new FileStream(
            path,
            FileMode.Open,
            FileAccess.Read,
            FileShare.Read,
            1024 * 1024,
            FileOptions.Asynchronous | FileOptions.SequentialScan);
        var digest = await SHA256.HashDataAsync(stream, cancellationToken).ConfigureAwait(false);
        return Convert.ToHexString(digest).ToLowerInvariant();
    }

    private static void DeleteWorkArtifacts(TransferSpec spec)
    {
        TryDelete(spec.PartialPath);
        TryDelete(spec.CheckpointPath);
        TryDelete(spec.CheckpointTempPath);
    }

    private static void TryDelete(string path)
    {
        try
        {
            File.Delete(path);
        }
        catch (IOException)
        {
            // Covers DirectoryNotFoundException and a file held open by a scanner.
        }
        catch (UnauthorizedAccessException)
        {
        }
    }

    private void RemoveTerminalTask(TransferControl control)
    {
        if (_tasks.TryGetValue(control.Spec.TaskId, out var current) &&
            ReferenceEquals(current, control))
        {
            _tasks.TryRemove(control.Spec.TaskId, out _);
        }
    }

    // ---------------------------------------------------------------- events

    private void EmitState(string type, string taskId) => _writer.Write(writer =>
    {
        writer.WriteString("type", type);
        writer.WriteString("taskId", taskId);
    });

    private void EmitHeaders(
        string taskId,
        long totalBytes,
        HttpStatusCode status,
        Version version,
        bool supportsRanges,
        int maxConnectionCount,
        string transferMode,
        string? entityTag,
        string? lastModified) => _writer.Write(writer =>
    {
        writer.WriteString("type", "headers");
        writer.WriteString("taskId", taskId);
        writer.WriteNumber("statusCode", (int)status);
        writer.WriteNumber("totalBytes", totalBytes);
        writer.WriteString("httpVersion", version.ToString());
        writer.WriteBoolean("supportsRanges", supportsRanges);
        // Transfers open one lane and escalate only while it pays off, so this is the
        // ceiling the planner may reach. Live counts arrive on the progress events.
        writer.WriteNumber("connectionCount", transferMode == "parallel_range" ? 1 : maxConnectionCount);
        writer.WriteNumber("maxConnectionCount", maxConnectionCount);
        writer.WriteString("transferMode", transferMode);
        if (!string.IsNullOrWhiteSpace(entityTag))
        {
            writer.WriteString("etag", entityTag);
        }
        if (!string.IsNullOrWhiteSpace(lastModified))
        {
            writer.WriteString("lastModified", lastModified);
        }
    });

    private void EmitProgress(TransferControl control)
    {
        var now = Stopwatch.GetTimestamp();
        var downloaded = Interlocked.Read(ref control.DownloadedBytes);
        var lastTicks = control.LastSampleTicks;
        var elapsed = (now - lastTicks) / (double)Stopwatch.Frequency;
        if (elapsed <= 0)
        {
            return;
        }

        var rawInstantBps = (downloaded - control.LastSampleBytes) / elapsed;
        if (rawInstantBps < 0)
        {
            rawInstantBps = 0;
        }
        var alpha = 1 - Math.Exp(-elapsed / 0.75);
        control.SmoothedBps = control.SmoothedBps <= 0
            ? rawInstantBps
            : control.SmoothedBps + (alpha * (rawInstantBps - control.SmoothedBps));
        control.LastSampleTicks = now;
        control.LastSampleBytes = downloaded;

        var activeTicks = control.CurrentActiveTicks();
        var averageBps = AverageBytesPerSecond(Interlocked.Read(ref control.WireBytes), activeTicks);
        var smoothed = control.SmoothedBps;

        _writer.Write(writer =>
        {
            writer.WriteString("type", "progress");
            writer.WriteString("taskId", control.Spec.TaskId);
            writer.WriteNumber("downloadedBytes", downloaded);
            writer.WriteNumber("totalBytes", control.TotalBytes);
            writer.WriteNumber("instantBps", smoothed);
            writer.WriteNumber("rawInstantBps", rawInstantBps);
            writer.WriteNumber("windowBps", smoothed);
            writer.WriteNumber("averageBps", averageBps);
            writer.WriteNumber("activeTicks", activeTicks);
            writer.WriteNumber("connectionCount", control.ConnectionCount);
        });
    }

    private void EmitCompleted(TransferControl control)
    {
        var activeTicks = control.CurrentActiveTicks();
        var averageBps = AverageBytesPerSecond(Interlocked.Read(ref control.WireBytes), activeTicks);
        var downloaded = Interlocked.Read(ref control.DownloadedBytes);
        _writer.Write(writer =>
        {
            writer.WriteString("type", "completed");
            writer.WriteString("taskId", control.Spec.TaskId);
            writer.WriteNumber("downloadedBytes", downloaded);
            writer.WriteNumber("totalBytes", control.TotalBytes);
            writer.WriteNumber("averageBps", averageBps);
            writer.WriteNumber("activeTicks", activeTicks);
        });
    }

    private void EmitRetry(string taskId, int attempt, string error) => _writer.Write(writer =>
    {
        writer.WriteString("type", "retrying");
        writer.WriteString("taskId", taskId);
        writer.WriteNumber("attempt", attempt);
        writer.WriteString("error", error);
    });

    private void EmitSegmentRetry(string taskId, int lane, int attempt, string error) =>
        _writer.Write(writer =>
        {
            writer.WriteString("type", "segmentRetrying");
            writer.WriteString("taskId", taskId);
            writer.WriteNumber("lane", lane);
            writer.WriteNumber("attempt", attempt);
            writer.WriteString("error", error);
        });

    private void EmitFailure(string taskId, string error) => _writer.Write(writer =>
    {
        writer.WriteString("type", "failed");
        writer.WriteString("taskId", taskId);
        writer.WriteString("error", error);
    });

    private static double AverageBytesPerSecond(long bytes, long activeTicks)
    {
        var seconds = Math.Max(0.001, activeTicks / (double)Stopwatch.Frequency);
        return bytes / seconds;
    }

    // ---------------------------------------------------------------- disposal

    public async ValueTask DisposeAsync()
    {
        _shutdown.Cancel();

        foreach (var control in _tasks.Values)
        {
            control.StopMode = StopMode.Pause;
            try
            {
                control.Cancellation.Cancel();
            }
            catch (ObjectDisposedException)
            {
            }
        }

        foreach (var control in _tasks.Values)
        {
            var execution = control.Execution;
            if (execution is null)
            {
                continue;
            }
            try
            {
                await execution.WaitAsync(TimeSpan.FromSeconds(10)).ConfigureAwait(false);
            }
            catch (Exception)
            {
            }
        }

        // Flush any progress made between the last tick and shutdown, so a host restart
        // resumes from where the bytes actually are.
        foreach (var control in _tasks.Values)
        {
            if (Interlocked.Exchange(ref control.CheckpointDirty, 0) == 0)
            {
                continue;
            }
            await SaveCheckpointAsync(control).ConfigureAwait(false);
        }

        foreach (var control in _tasks.Values)
        {
            try
            {
                control.Cancellation.Dispose();
            }
            catch (Exception)
            {
            }
        }

        try
        {
            await Task.WhenAll(_progressPump, _checkpointPump).WaitAsync(TimeSpan.FromSeconds(3))
                .ConfigureAwait(false);
        }
        catch (Exception)
        {
        }

        _clients.Dispose();
        _shutdown.Dispose();
    }

    // ---------------------------------------------------------------- state

    private sealed class TransferControl(TransferSpec spec)
    {
        public TransferSpec Spec { get; } = spec;

        public object Sync { get; } = new();

        public CancellationTokenSource Cancellation = new();

        public volatile StopMode StopMode;

        public volatile TransferState State = TransferState.Pending;

        public Task? Execution;

        public DateTimeOffset? StartedAt;

        public volatile TransferPlan? Plan;

        public volatile bool ForceStreamMode;

        public long DownloadedBytes;

        public long TotalBytes;

        public long WireBytes;

        public long ActiveTicks;

        public long AttemptStartTicks;

        public double SmoothedBps;

        public long LastSampleTicks = Stopwatch.GetTimestamp();

        public long LastSampleBytes;

        public int CheckpointDirty;

        public int ConnectionCount = 1;

        /// <summary>
        /// Serializes checkpoint writes. The periodic pump, a pause, and shutdown can all
        /// try to save the same task at once, and they share one ".state.tmp" path.
        /// </summary>
        public SemaphoreSlim CheckpointGate { get; } = new(1, 1);

        public void BeginAttempt() => Volatile.Write(ref AttemptStartTicks, Stopwatch.GetTimestamp());

        public void EndAttempt()
        {
            var started = Interlocked.Exchange(ref AttemptStartTicks, 0);
            if (started > 0)
            {
                Interlocked.Add(ref ActiveTicks, Stopwatch.GetTimestamp() - started);
            }
        }

        public long CurrentActiveTicks()
        {
            var accumulated = Interlocked.Read(ref ActiveTicks);
            var started = Volatile.Read(ref AttemptStartTicks);
            return started > 0 ? accumulated + (Stopwatch.GetTimestamp() - started) : accumulated;
        }

        public void ResetSpeedSamples()
        {
            LastSampleTicks = Stopwatch.GetTimestamp();
            LastSampleBytes = Interlocked.Read(ref DownloadedBytes);
            SmoothedBps = 0;
        }

        public void ResetProgress()
        {
            Interlocked.Exchange(ref DownloadedBytes, 0);
            Plan = null;
            ResetSpeedSamples();
        }

        public void MarkCheckpointDirty() => Interlocked.Exchange(ref CheckpointDirty, 1);
    }

    private sealed class TransferContext
    {
        private readonly object _errorSync = new();
        private readonly CancellationTokenSource _fatal;
        private Exception? _error;
        private bool _errorIsFatal;

        public TransferContext(
            TransferControl control,
            TransferPlan plan,
            SafeFileHandle handle,
            CancellationTokenSource fatal)
        {
            Control = control;
            Plan = plan;
            Handle = handle;
            _fatal = fatal;
        }

        public TransferControl Control { get; }

        public TransferPlan Plan { get; }

        public SafeFileHandle Handle { get; }

        public int BusyLanes;

        /// <summary>
        /// Lanes with an index below this are allowed to take work. Owned by the lane
        /// governor; lane 0 is always enabled.
        /// </summary>
        public int TargetLanes = 1;

        /// <summary>
        /// Stopwatch tick of each lane's first delivered byte, zero until then. The
        /// governor must not judge a lane that has not started streaming: on a
        /// high-latency path DNS + TLS + slow start eat the whole judgment window,
        /// and an unfairly judged lane gets retired exactly where it helps most.
        /// </summary>
        public long[] LaneFirstByteTicks = Array.Empty<long>();

        public void MarkLaneStreaming(int lane)
        {
            var slots = LaneFirstByteTicks;
            if (lane < slots.Length)
            {
                Interlocked.CompareExchange(ref slots[lane], Stopwatch.GetTimestamp(), 0);
            }
        }

        public Exception? Error
        {
            get
            {
                lock (_errorSync)
                {
                    return _error;
                }
            }
        }

        public void ReportError(Exception error, bool isFatal)
        {
            lock (_errorSync)
            {
                // A fatal cause (range support lost, resource changed) explains every
                // downstream timeout, so it must win over whichever lane happened to fail
                // first.
                if (_error is null || (isFatal && !_errorIsFatal))
                {
                    _error = error;
                    _errorIsFatal = isFatal;
                }
            }

            if (isFatal)
            {
                try
                {
                    _fatal.Cancel();
                }
                catch (ObjectDisposedException)
                {
                }
            }
        }
    }

    private sealed class ProbeResult : IDisposable
    {
        private Stream? _body;

        public ProbeResult(
            HttpResponseMessage? response,
            Stream? body,
            long totalBytes,
            bool supportsRanges,
            string? entityTag,
            string? lastModified,
            string effectiveUrl,
            Version httpVersion,
            HttpStatusCode statusCode)
        {
            Response = response;
            _body = body;
            TotalBytes = totalBytes;
            SupportsRanges = supportsRanges;
            ETag = entityTag;
            LastModified = lastModified;
            EffectiveUrl = effectiveUrl;
            HttpVersion = httpVersion;
            StatusCode = statusCode;
        }

        public HttpResponseMessage? Response { get; }

        public long TotalBytes { get; }

        public bool SupportsRanges { get; }

        public string? ETag { get; }

        public string? LastModified { get; }

        public string EffectiveUrl { get; }

        public Version HttpVersion { get; }

        public HttpStatusCode StatusCode { get; }

        public bool HasBody => _body is not null;

        public Stream? TakeBody()
        {
            var body = _body;
            _body = null;
            return body;
        }

        public void Dispose()
        {
            _body?.Dispose();
            Response?.Dispose();
        }
    }

    private enum StopMode
    {
        None,
        Pause,
        Cancel,
        CancelAndDelete,
    }

    private enum TransferState
    {
        Pending,
        Queued,
        Running,
        Paused,
        Completed,
        Failed,
        Cancelled,
    }

    /// <summary>Aborts the whole transfer; retrying the chunk cannot help.</summary>
    private class FatalTransferException(string message) : IOException(message);

    private sealed class RangeNotSupportedException(string message) : FatalTransferException(message);

    private sealed class ValidatorChangedException(string message) : FatalTransferException(message);

    private sealed class RangeValidationException(string message) : FatalTransferException(message);

    private sealed class ChecksumMismatchException(string message) : FatalTransferException(message);

    /// <summary>Discard everything on disk and plan the transfer again.</summary>
    private sealed class RestartFromScratchException(string message) : IOException(message);

    private sealed class LaneStalledException(string message) : IOException(message);
}
