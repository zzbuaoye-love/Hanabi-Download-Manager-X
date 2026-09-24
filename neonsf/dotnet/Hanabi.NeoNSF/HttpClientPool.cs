using System.Collections.Concurrent;
using System.Net;
using System.Net.Http;
using System.Net.Sockets;

namespace Hanabi.NeoNSF;

/// <summary>
/// One <see cref="HttpClient"/> per (connection profile, lane).
/// </summary>
/// <remarks>
/// The lane dimension is the whole point. Connection pooling in .NET is per
/// SocketsHttpHandler, so sharing a single handler across parallel ranges means HTTP/2
/// multiplexes every range onto one TCP connection — one congestion window, one
/// head-of-line queue, and one per-connection server throttle for all of them, which
/// erases the entire benefit of ranged parallelism. EnableMultipleHttp2Connections does
/// not help because it only opens a second connection once the stream limit is reached,
/// and 8 or 16 streams never reach it. Giving every lane its own handler guarantees a
/// real independent TCP connection regardless of negotiated protocol version.
/// </remarks>
internal sealed class HttpClientPool : IDisposable
{
    private const int MaxConnectCandidates = 4;
    private const int ConnectStaggerMilliseconds = 250;

    private readonly ConcurrentDictionary<ClientKey, HttpClient> _clients = new();
    private bool _disposed;

    public HttpClient Get(TransferSpec spec, int lane = 0)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        var proxy = spec.Proxy;
        var key = new ClientKey(
            lane,
            spec.AllowInsecureTls,
            spec.ConnectionTimeoutSeconds,
            spec.UseSystemProxy,
            spec.PreferIpv6,
            proxy?.Type ?? string.Empty,
            proxy?.Host ?? string.Empty,
            proxy?.Port ?? 0,
            proxy?.Username ?? string.Empty,
            proxy?.Password ?? string.Empty);
        return _clients.GetOrAdd(key, static k => CreateClient(k));
    }

    /// <summary>
    /// Drops a lane's pooled sockets so the next attempt reconnects, which usually
    /// lands on a different CDN edge. Used when a lane stalls or errors out.
    /// </summary>
    public void RecycleLane(TransferSpec spec, int lane)
    {
        var proxy = spec.Proxy;
        var key = new ClientKey(
            lane,
            spec.AllowInsecureTls,
            spec.ConnectionTimeoutSeconds,
            spec.UseSystemProxy,
            spec.PreferIpv6,
            proxy?.Type ?? string.Empty,
            proxy?.Host ?? string.Empty,
            proxy?.Port ?? 0,
            proxy?.Username ?? string.Empty,
            proxy?.Password ?? string.Empty);
        if (_clients.TryRemove(key, out var client))
        {
            client.Dispose();
        }
    }

    private static HttpClient CreateClient(ClientKey key)
    {
        var handler = new SocketsHttpHandler
        {
            AllowAutoRedirect = true,
            MaxAutomaticRedirections = 10,
            AutomaticDecompression = DecompressionMethods.None,
            ConnectTimeout = TimeSpan.FromSeconds(key.ConnectionTimeoutSeconds),
            EnableMultipleHttp2Connections = true,
            // A lane owns one logical connection; the small headroom covers redirects
            // and the brief overlap while a stalled connection is being replaced.
            MaxConnectionsPerServer = 4,
            PooledConnectionIdleTimeout = TimeSpan.FromSeconds(90),
            PooledConnectionLifetime = TimeSpan.FromMinutes(15),
            ResponseDrainTimeout = TimeSpan.FromSeconds(2),
            UseCookies = false,
            UseProxy = key.UseSystemProxy || !string.IsNullOrWhiteSpace(key.ProxyHost),
            // Default is 64 KiB, which caps a single HTTP/2 stream at roughly
            // 64KiB/RTT. On a 100 ms path that is ~5 Mbps no matter how fast the link is.
            InitialHttp2StreamWindowSize = 4 * 1024 * 1024,
        };

        if (key.AllowInsecureTls)
        {
            handler.SslOptions.RemoteCertificateValidationCallback = static (_, _, _, _) => true;
        }

        if (!string.IsNullOrWhiteSpace(key.ProxyHost))
        {
            var scheme = key.ProxyType.ToLowerInvariant() switch
            {
                "socks5" => "socks5",
                "socks4" => "socks4",
                "https" => "https",
                _ => "http",
            };
            var webProxy = new WebProxy(new Uri($"{scheme}://{key.ProxyHost}:{key.ProxyPort}"));
            if (!string.IsNullOrWhiteSpace(key.ProxyUsername))
            {
                webProxy.Credentials = new NetworkCredential(key.ProxyUsername, key.ProxyPassword);
            }
            handler.Proxy = webProxy;
        }
        else if (!key.UseSystemProxy)
        {
            // Happy Eyeballs only for direct connections. Behind a proxy the transport
            // endpoint is the proxy itself and the default connector is the safer path.
            var preferIpv6 = key.PreferIpv6;
            handler.ConnectCallback = (context, cancellationToken) =>
                ConnectAsync(preferIpv6, context, cancellationToken);
        }

        return new HttpClient(handler, disposeHandler: true)
        {
            // Per-phase deadlines are enforced with linked CancellationTokenSources so a
            // multi-hour transfer is never killed by a single global timeout.
            Timeout = Timeout.InfiniteTimeSpan,
        };
    }

    /// <summary>
    /// RFC 8305 style connection racing. A dual-stack host whose IPv6 route is
    /// blackholed otherwise burns the full ConnectTimeout before .NET falls back,
    /// which is a very common failure mode on consumer networks.
    /// </summary>
    private static async ValueTask<Stream> ConnectAsync(
        bool preferIpv6,
        SocketsHttpConnectionContext context,
        CancellationToken cancellationToken)
    {
        var host = context.DnsEndPoint.Host;
        var port = context.DnsEndPoint.Port;

        var addresses = IPAddress.TryParse(host, out var literal)
            ? new[] { literal }
            : await Dns.GetHostAddressesAsync(host, cancellationToken).ConfigureAwait(false);

        if (addresses.Length == 0)
        {
            throw new SocketException((int)SocketError.HostNotFound);
        }

        var candidates = OrderCandidates(addresses, preferIpv6);
        var errors = new ConcurrentQueue<Exception>();
        using var race = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);

        var attempts = new List<Task<Socket?>>(candidates.Count);
        for (var index = 0; index < candidates.Count; index++)
        {
            attempts.Add(AttemptAsync(
                candidates[index],
                port,
                TimeSpan.FromMilliseconds(ConnectStaggerMilliseconds * index),
                errors,
                race.Token));
        }

        while (attempts.Count > 0)
        {
            var finished = await Task.WhenAny(attempts).ConfigureAwait(false);
            attempts.Remove(finished);
            var socket = await finished.ConfigureAwait(false);
            if (socket is null)
            {
                continue;
            }

            race.Cancel();
            DiscardLosers(attempts);
            return new NetworkStream(socket, ownsSocket: true);
        }

        cancellationToken.ThrowIfCancellationRequested();
        throw errors.TryDequeue(out var error)
            ? error
            : new SocketException((int)SocketError.HostUnreachable);
    }

    private static async Task<Socket?> AttemptAsync(
        IPAddress address,
        int port,
        TimeSpan delay,
        ConcurrentQueue<Exception> errors,
        CancellationToken cancellationToken)
    {
        Socket? socket = null;
        try
        {
            if (delay > TimeSpan.Zero)
            {
                await Task.Delay(delay, cancellationToken).ConfigureAwait(false);
            }
            socket = new Socket(address.AddressFamily, SocketType.Stream, ProtocolType.Tcp)
            {
                NoDelay = true,
            };
            await socket.ConnectAsync(new IPEndPoint(address, port), cancellationToken)
                .ConfigureAwait(false);
            return socket;
        }
        catch (OperationCanceledException)
        {
            socket?.Dispose();
            return null;
        }
        catch (Exception error)
        {
            socket?.Dispose();
            errors.Enqueue(error);
            return null;
        }
    }

    private static void DiscardLosers(List<Task<Socket?>> pending)
    {
        if (pending.Count == 0)
        {
            return;
        }
        var losers = pending.ToArray();
        _ = Task.Run(async () =>
        {
            foreach (var loser in losers)
            {
                try
                {
                    (await loser.ConfigureAwait(false))?.Dispose();
                }
                catch (Exception)
                {
                }
            }
        });
    }

    private static List<IPAddress> OrderCandidates(IPAddress[] addresses, bool preferIpv6)
    {
        var primary = new List<IPAddress>();
        var secondary = new List<IPAddress>();
        foreach (var address in addresses)
        {
            var isIpv6 = address.AddressFamily == AddressFamily.InterNetworkV6;
            if (isIpv6 == preferIpv6)
            {
                primary.Add(address);
            }
            else
            {
                secondary.Add(address);
            }
        }

        var ordered = new List<IPAddress>(addresses.Length);
        var rounds = Math.Max(primary.Count, secondary.Count);
        for (var index = 0; index < rounds && ordered.Count < MaxConnectCandidates; index++)
        {
            if (index < primary.Count)
            {
                ordered.Add(primary[index]);
            }
            if (ordered.Count < MaxConnectCandidates && index < secondary.Count)
            {
                ordered.Add(secondary[index]);
            }
        }
        return ordered;
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }
        _disposed = true;
        foreach (var client in _clients.Values)
        {
            client.Dispose();
        }
        _clients.Clear();
    }

    private sealed record ClientKey(
        int Lane,
        bool AllowInsecureTls,
        int ConnectionTimeoutSeconds,
        bool UseSystemProxy,
        bool PreferIpv6,
        string ProxyType,
        string ProxyHost,
        int ProxyPort,
        string ProxyUsername,
        string ProxyPassword);
}
