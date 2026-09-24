using System.Buffers;
using System.Text.Json;

namespace Hanabi.NeoNSF;

/// <summary>
/// Writes newline-delimited JSON events to the host.
/// </summary>
/// <remarks>
/// This deliberately bypasses <see cref="Console.Out"/>. Console.Out encodes through
/// Console.OutputEncoding, which on Windows resolves to the console code page
/// (GBK on a zh-CN machine when a console is attached, UTF-8 when it is not).
/// That makes the wire encoding depend on how the process was launched and corrupts
/// every non-ASCII file name and error message. Writing UTF-8 bytes straight to the
/// standard output handle removes the ambiguity, and reusing one buffer plus one
/// Utf8JsonWriter keeps the hot progress path allocation-free.
/// </remarks>
internal sealed class ProtocolWriter : IDisposable
{
    private readonly Stream _output;
    private readonly ArrayBufferWriter<byte> _buffer = new(16 * 1024);
    private readonly Utf8JsonWriter _json;
    private readonly object _gate = new();
    private bool _broken;

    public ProtocolWriter(Stream? output = null)
    {
        _output = output ?? Console.OpenStandardOutput();
        _json = new Utf8JsonWriter(_buffer, new JsonWriterOptions { SkipValidation = true });
    }

    /// <summary>Raised once the host has closed its end of the pipe.</summary>
    public bool IsBroken => Volatile.Read(ref _broken);

    public void Write(Action<Utf8JsonWriter> payload)
    {
        lock (_gate)
        {
            if (_broken)
            {
                return;
            }

            _buffer.Clear();
            _json.Reset(_buffer);
            try
            {
                _json.WriteStartObject();
                payload(_json);
                _json.WriteEndObject();
                _json.Flush();
            }
            catch (Exception)
            {
                // A half-written object would desynchronize the stream. Drop it whole.
                _buffer.Clear();
                _json.Reset(_buffer);
                throw;
            }

            _buffer.Write("\n"u8);

            try
            {
                _output.Write(_buffer.WrittenSpan);
                _output.Flush();
            }
            catch (IOException)
            {
                _broken = true;
            }
            catch (ObjectDisposedException)
            {
                _broken = true;
            }
        }
    }

    public void Response(string? requestId, bool ok, string? error = null)
    {
        Write(writer =>
        {
            writer.WriteString("type", "response");
            if (!string.IsNullOrWhiteSpace(requestId))
            {
                writer.WriteString("requestId", requestId);
            }
            writer.WriteBoolean("ok", ok);
            if (!string.IsNullOrWhiteSpace(error))
            {
                writer.WriteString("error", error);
            }
        });
    }

    public void Dispose()
    {
        lock (_gate)
        {
            _json.Dispose();
            try
            {
                _output.Flush();
            }
            catch (IOException)
            {
            }
            catch (ObjectDisposedException)
            {
            }
        }
    }
}
