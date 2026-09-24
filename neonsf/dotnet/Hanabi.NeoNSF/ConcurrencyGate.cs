namespace Hanabi.NeoNSF;

/// <summary>
/// A FIFO async semaphore whose limit can be changed while callers are queued.
/// </summary>
/// <remarks>
/// Without this the engine starts every enqueued transfer immediately, so a queue of
/// 100 tasks opens 100 x maxConnections sockets and exhausts the local NAT table long
/// before the network saturates. SemaphoreSlim cannot be resized, and the host is
/// allowed to change the limit at runtime through the "configure" command.
/// </remarks>
internal sealed class ConcurrencyGate
{
    private readonly object _sync = new();
    private readonly LinkedList<TaskCompletionSource<bool>> _waiters = new();
    private int _limit;
    private int _active;

    public ConcurrencyGate(int limit) => _limit = Math.Max(1, limit);

    public int Limit
    {
        get
        {
            lock (_sync)
            {
                return _limit;
            }
        }
    }

    public int Active
    {
        get
        {
            lock (_sync)
            {
                return _active;
            }
        }
    }

    public int Waiting
    {
        get
        {
            lock (_sync)
            {
                return _waiters.Count;
            }
        }
    }

    public void SetLimit(int limit)
    {
        List<TaskCompletionSource<bool>>? promoted;
        lock (_sync)
        {
            _limit = Math.Max(1, limit);
            promoted = PromoteLocked();
        }
        CompletePromoted(promoted);
    }

    /// <summary>Takes a slot only if one is free right now.</summary>
    public bool TryEnter()
    {
        lock (_sync)
        {
            if (_active >= _limit)
            {
                return false;
            }
            _active++;
            return true;
        }
    }

    public async Task EnterAsync(CancellationToken cancellationToken)
    {
        TaskCompletionSource<bool> waiter;
        LinkedListNode<TaskCompletionSource<bool>> node;
        lock (_sync)
        {
            if (_active < _limit)
            {
                _active++;
                return;
            }
            waiter = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
            node = _waiters.AddLast(waiter);
        }

        using var registration = cancellationToken.Register(
            static state => ((TaskCompletionSource<bool>)state!).TrySetCanceled(),
            waiter);
        try
        {
            await waiter.Task.ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            lock (_sync)
            {
                if (node.List is not null)
                {
                    _waiters.Remove(node);
                }
            }
            throw;
        }
    }

    public void Release()
    {
        List<TaskCompletionSource<bool>>? promoted;
        lock (_sync)
        {
            if (_active > 0)
            {
                _active--;
            }
            promoted = PromoteLocked();
        }
        CompletePromoted(promoted);
    }

    private List<TaskCompletionSource<bool>>? PromoteLocked()
    {
        List<TaskCompletionSource<bool>>? promoted = null;
        while (_active < _limit && _waiters.First is { } first)
        {
            _waiters.RemoveFirst();
            if (first.Value.Task.IsCompleted)
            {
                // Already cancelled while queued; it never took a slot.
                continue;
            }
            _active++;
            (promoted ??= new List<TaskCompletionSource<bool>>()).Add(first.Value);
        }
        return promoted;
    }

    private void CompletePromoted(List<TaskCompletionSource<bool>>? promoted)
    {
        if (promoted is null)
        {
            return;
        }
        foreach (var waiter in promoted)
        {
            if (!waiter.TrySetResult(true))
            {
                // Cancellation won the race after we reserved the slot. Hand it back
                // so the count cannot drift upward over time.
                Release();
            }
        }
    }
}
