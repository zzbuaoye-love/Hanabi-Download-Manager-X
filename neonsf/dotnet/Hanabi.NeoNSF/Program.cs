using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Text.Json;
using Hanabi.NeoNSF;

const string EngineName = "NeoNSF";
const string EngineVersion = "1.0.0";
const int ProtocolVersion = 2;
const int MaxConnectionsPerTask = 16;

var http3Supported = DetectHttp3();

if (args.Contains("--probe", StringComparer.OrdinalIgnoreCase))
{
    Console.WriteLine(
        $"{{\"name\":\"{EngineName}\",\"version\":\"{EngineVersion}\"," +
        $"\"protocolVersion\":{ProtocolVersion},\"http3\":{(http3Supported ? "true" : "false")}," +
        "\"ready\":true}");
    return 0;
}

using var protocol = new ProtocolWriter();
await using var engine = new NeoNsfEngine(protocol);

// The host owns this process. If it dies without a clean shutdown the pipe usually
// breaks and the read loop ends by itself, but a detached or suspended parent can leave
// the sidecar downloading forever, so watch the PID explicitly as well.
StartParentWatchdog(args, engine, protocol);

protocol.Write(writer =>
{
    writer.WriteString("type", "ready");
    writer.WriteString("name", EngineName);
    writer.WriteString("version", EngineVersion);
    writer.WriteNumber("protocolVersion", ProtocolVersion);
    writer.WriteStartObject("capabilities");
    writer.WriteBoolean("singleConnection", true);
    writer.WriteBoolean("multiRange", true);
    writer.WriteBoolean("unknownSizePlanning", true);
    writer.WriteNumber("maxConnectionsPerTask", MaxConnectionsPerTask);
    writer.WriteBoolean("pauseResume", true);
    writer.WriteBoolean("http2", true);
    // Reported from the runtime rather than assumed: a NativeAOT build without msquic
    // available cannot do HTTP/3 and must not claim it.
    writer.WriteBoolean("http3", http3Supported);
    writer.WriteBoolean("proxy", true);
    writer.WriteBoolean("chunkedPlanning", true);
    writer.WriteBoolean("perLaneConnections", true);
    writer.WriteBoolean("segmentRetry", true);
    writer.WriteBoolean("sha256Verification", true);
    writer.WriteBoolean("rateLimit", true);
    writer.WriteBoolean("concurrencyGate", true);
    writer.WriteEndObject();
});

// Console.In would decode through Console.InputEncoding, which resolves to the console
// code page on Windows. On a zh-CN machine that is GBK when a console is attached and
// UTF-8 when it is not, so file paths with non-ASCII characters decoded differently
// depending on how the process was started.
using var input = new StreamReader(
    Console.OpenStandardInput(),
    new UTF8Encoding(encoderShouldEmitUTF8Identifier: false),
    detectEncodingFromByteOrderMarks: false,
    bufferSize: 64 * 1024);

while (await input.ReadLineAsync().ConfigureAwait(false) is { } line)
{
    if (string.IsNullOrWhiteSpace(line))
    {
        continue;
    }

    string? requestId = null;
    try
    {
        using var document = JsonDocument.Parse(line);
        var root = document.RootElement;
        requestId = root.TryGetProperty("requestId", out var requestNode) &&
                    requestNode.ValueKind == JsonValueKind.String
            ? requestNode.GetString()
            : null;

        var command = root.GetProperty("command").GetString();
        switch (command)
        {
            case "ping":
                protocol.Response(requestId, true);
                break;

            case "enqueue":
            {
                var spec = TransferSpec.Parse(root);
                var accepted = engine.Enqueue(spec, out var error);
                protocol.Response(requestId, accepted, error);
                break;
            }

            case "pause":
            {
                var taskId = root.GetProperty("payload").GetProperty("taskId").GetString() ?? string.Empty;
                protocol.Response(requestId, engine.Pause(taskId), "Task is not active.");
                break;
            }

            case "resume":
            {
                // Resuming waits for the previous run to unwind, which can take a moment.
                // Answer off the reader loop so pings and pauses stay responsive.
                var taskId = root.GetProperty("payload").GetProperty("taskId").GetString() ?? string.Empty;
                var pending = requestId;
                _ = Task.Run(async () =>
                {
                    try
                    {
                        var resumed = await engine.ResumeAsync(taskId).ConfigureAwait(false);
                        protocol.Response(pending, resumed, "Task is not paused.");
                    }
                    catch (Exception error)
                    {
                        protocol.Response(pending, false, error.Message);
                    }
                });
                break;
            }

            case "cancel":
            {
                var payload = root.GetProperty("payload");
                var taskId = payload.GetProperty("taskId").GetString() ?? string.Empty;
                var deletePartial = !payload.TryGetProperty("deletePartial", out var deleteNode) ||
                                    deleteNode.ValueKind != JsonValueKind.False;
                protocol.Response(requestId, engine.Cancel(taskId, deletePartial), "Task was not found.");
                break;
            }

            case "configure":
            {
                var payload = root.GetProperty("payload");
                int? maxConcurrent = payload.TryGetProperty("maxConcurrentTransfers", out var concurrentNode) &&
                                     concurrentNode.ValueKind == JsonValueKind.Number
                    ? Math.Clamp(concurrentNode.GetInt32(), 1, 32)
                    : null;
                long? maxRate = payload.TryGetProperty("maxBytesPerSecond", out var rateNode) &&
                                rateNode.ValueKind == JsonValueKind.Number
                    ? Math.Max(0, rateNode.GetInt64())
                    : null;
                engine.Configure(maxConcurrent, maxRate);
                protocol.Response(requestId, true);
                break;
            }

            case "shutdown":
                protocol.Response(requestId, true);
                return 0;

            default:
                protocol.Response(requestId, false, $"Unknown command '{command}'.");
                break;
        }
    }
    catch (Exception error)
    {
        protocol.Response(requestId, false, error.Message);
    }
}

return 0;

/// <summary>
/// HTTP/3 needs msquic plus an OS with QUIC-capable TLS. QuicConnection.IsSupported is
/// the direct answer but is still gated behind EnablePreviewFeatures on .NET 8, which is
/// not worth turning on for the whole assembly, so probe the native library instead.
/// Reporting this honestly matters: the host advertises engine capabilities to the UI.
/// </summary>
static bool DetectHttp3()
{
    try
    {
        // Schannel gained QUIC support in Windows Server 2022 / Windows 11 (build 20348).
        if (OperatingSystem.IsWindows() && !OperatingSystem.IsWindowsVersionAtLeast(10, 0, 20348))
        {
            return false;
        }
        if (!System.Runtime.InteropServices.NativeLibrary.TryLoad("msquic", out var handle))
        {
            return false;
        }
        System.Runtime.InteropServices.NativeLibrary.Free(handle);
        return true;
    }
    catch (Exception)
    {
        return false;
    }
}

static void StartParentWatchdog(string[] args, NeoNsfEngine engine, ProtocolWriter protocol)
{
    var parentPid = ParseParentPid(args);
    if (parentPid is not { } pid)
    {
        return;
    }

    _ = Task.Run(async () =>
    {
        try
        {
            using var parent = Process.GetProcessById(pid);
            await parent.WaitForExitAsync().ConfigureAwait(false);
        }
        catch (ArgumentException)
        {
            // Already gone by the time we looked.
        }
        catch (InvalidOperationException)
        {
        }

        try
        {
            // Give in-flight lanes a chance to checkpoint so the next launch resumes
            // instead of restarting.
            await engine.DisposeAsync().AsTask().WaitAsync(TimeSpan.FromSeconds(8)).ConfigureAwait(false);
        }
        catch (Exception)
        {
        }

        protocol.Dispose();
        Environment.Exit(0);
    });
}

static int? ParseParentPid(string[] args)
{
    for (var index = 0; index < args.Length; index++)
    {
        if (!args[index].Equals("--parent-pid", StringComparison.OrdinalIgnoreCase))
        {
            continue;
        }
        if (index + 1 < args.Length &&
            int.TryParse(args[index + 1], NumberStyles.Integer, CultureInfo.InvariantCulture, out var pid) &&
            pid > 0)
        {
            return pid;
        }
        return null;
    }
    return null;
}
