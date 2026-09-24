using System.Diagnostics;

namespace Hanabi.NeoNSF;

/// <summary>
/// Token bucket shared by every lane of every transfer, so the configured speed cap
/// applies to aggregate throughput rather than per connection.
/// </summary>
internal sealed class RateLimiter
{
    private readonly object _sync = new();
    private long _bytesPerSecond;
    private double _tokens;
    private long _lastTicks;

    public RateLimiter(long bytesPerSecond)
    {
        _bytesPerSecond = Math.Max(0, bytesPerSecond);
        _tokens = _bytesPerSecond;
        _lastTicks = Stopwatch.GetTimestamp();
    }

    /// <summary>Zero means unlimited.</summary>
    public long BytesPerSecond
    {
        get
        {
            lock (_sync)
            {
                return _bytesPerSecond;
            }
        }
    }

    public void SetRate(long bytesPerSecond)
    {
        lock (_sync)
        {
            _bytesPerSecond = Math.Max(0, bytesPerSecond);
            RefillLocked();
            _tokens = Math.Min(_tokens, _bytesPerSecond);
        }
    }

    /// <summary>
    /// Returns how many bytes the caller may read next, never more than
    /// <paramref name="desired"/> and never zero. Waits only when the bucket is dry.
    /// </summary>
    public async ValueTask<int> AcquireAsync(int desired, CancellationToken cancellationToken)
    {
        if (desired <= 0)
        {
            return 0;
        }

        while (true)
        {
            TimeSpan delay;
            lock (_sync)
            {
                if (_bytesPerSecond <= 0)
                {
                    return desired;
                }

                RefillLocked();
                if (_tokens >= 1)
                {
                    var grant = (int)Math.Min(desired, (long)_tokens);
                    if (grant < 1)
                    {
                        grant = 1;
                    }
                    _tokens -= grant;
                    return grant;
                }

                var deficitSeconds = (1 - _tokens) / _bytesPerSecond;
                delay = TimeSpan.FromMilliseconds(Math.Clamp(deficitSeconds * 1000, 1, 200));
            }

            await Task.Delay(delay, cancellationToken).ConfigureAwait(false);
        }
    }

    private void RefillLocked()
    {
        var now = Stopwatch.GetTimestamp();
        var elapsed = (double)(now - _lastTicks) / Stopwatch.Frequency;
        if (elapsed <= 0)
        {
            return;
        }
        _lastTicks = now;
        // Burst is capped at one second of budget so a long idle period cannot
        // release an unbounded spike.
        _tokens = Math.Min(_bytesPerSecond, _tokens + (elapsed * _bytesPerSecond));
    }
}
