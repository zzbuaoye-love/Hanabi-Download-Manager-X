using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using Microsoft.Win32.SafeHandles;

namespace Hanabi.NeoNSF;

/// <summary>
/// Marks a freshly created download target as an NTFS sparse file.
/// </summary>
/// <remarks>
/// Preallocating with SetLength only moves the end-of-file marker; NTFS leaves
/// ValidDataLength at zero. The first write to offset X then forces the kernel to
/// synchronously zero-fill [ValidDataLength, X). With parallel ranges the highest
/// segment starts near the end of the file, so a 4 GiB download stalls on ~4 GiB of
/// zero writes before a single payload byte lands. Setting FSCTL_SET_SPARSE first
/// makes those unwritten regions virtual, so the zero-fill never happens.
/// </remarks>
internal static partial class SparseFile
{
    private const uint FsctlSetSparse = 0x000900C4;

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool DeviceIoControl(
        SafeFileHandle device,
        uint controlCode,
        IntPtr inBuffer,
        uint inBufferSize,
        IntPtr outBuffer,
        uint outBufferSize,
        out uint bytesReturned,
        IntPtr overlapped);

    /// <summary>
    /// Best-effort. Returns false on non-Windows, on non-NTFS volumes, and on any
    /// failure — the download is still correct without it, just slower to start.
    /// </summary>
    public static bool TryMarkSparse(string path)
    {
        if (!OperatingSystem.IsWindows())
        {
            return false;
        }

        try
        {
            return MarkSparseWindows(path);
        }
        catch (Exception)
        {
            return false;
        }
    }

    [SupportedOSPlatform("windows")]
    private static bool MarkSparseWindows(string path)
    {
        // Opened synchronously on purpose: DeviceIoControl with a null OVERLAPPED
        // against a FILE_FLAG_OVERLAPPED handle is not valid, and the download
        // handle is always asynchronous.
        using var handle = File.OpenHandle(
            path,
            FileMode.Open,
            FileAccess.Write,
            FileShare.ReadWrite,
            FileOptions.None);
        return DeviceIoControl(
            handle,
            FsctlSetSparse,
            IntPtr.Zero,
            0,
            IntPtr.Zero,
            0,
            out _,
            IntPtr.Zero);
    }
}
