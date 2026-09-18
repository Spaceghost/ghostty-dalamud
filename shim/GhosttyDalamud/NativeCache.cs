using System;
using System.Diagnostics;
using System.IO;

namespace GhosttyDalamud;

// Release packages load the core directly. Only developer installations that
// include ghostty_loader.dll need an instance-owned writable hot-reload cache.
internal sealed class NativeCache : IDisposable
{
    private readonly string sourceCore;
    private readonly string? directory;
    private Stamp loaded;
    private Stamp? pending;
    private double nextPoll;
    private string? lastError;
    private bool disposed;
    private readonly record struct Stamp(long Length, long Modified);

    internal bool HotReloadEnabled => directory != null;
    internal string CorePath => directory == null ? sourceCore : Path.Combine(directory, "ghostty_core.dll");

    internal NativeCache(string installDirectory, string configDirectory)
    {
        sourceCore = Path.GetFullPath(Path.Combine(installDirectory, "ghostty_core.dll"));
        loaded = ReadStamp(sourceCore);
        string loader = Path.Combine(installDirectory, "ghostty_loader.dll");
        // A normal release ZIP intentionally has no development loader. Do not
        // create a cache or poll/copy an in-use DLL in this mode.
        if (!File.Exists(loader)) return;
        directory = Path.GetFullPath(Path.Combine(configDirectory, "native-cache",
            $"{Environment.ProcessId}-{Guid.NewGuid():N}"));
        Directory.CreateDirectory(directory);
        try
        {
            File.Copy(loader, Path.Combine(directory, "ghostty_loader.dll"));
            File.SetAttributes(Path.Combine(directory, "ghostty_loader.dll"), FileAttributes.Normal);
            loaded = CopyCore();
        }
        catch
        {
            Dispose();
            throw;
        }
    }

    private static Stamp ReadStamp(string path)
    {
        var info = new FileInfo(path);
        if (!info.Exists) throw new FileNotFoundException("Native core file is missing.", path);
        return new Stamp(info.Length, info.LastWriteTimeUtc.Ticks);
    }

    private Stamp CopyCore()
    {
        Stamp before = ReadStamp(sourceCore);
        string temporary = CorePath + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            using (var input = new FileStream(sourceCore, FileMode.Open, FileAccess.Read,
                       FileShare.ReadWrite | FileShare.Delete))
            using (var output = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                input.CopyTo(output);
            if (new FileInfo(temporary).Length != before.Length || ReadStamp(sourceCore) != before)
                throw new IOException("Native core changed during staging; keeping the previous copy.");
            File.Move(temporary, CorePath, overwrite: true);
            return before;
        }
        finally
        {
            try { File.Delete(temporary); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }

    internal string? Refresh() => Refresh((double)Stopwatch.GetTimestamp() / Stopwatch.Frequency);

    // Developer hot reload only: two equal observations avoid half-written builds.
    internal string? Refresh(double now)
    {
        if (disposed || directory == null || now < nextPoll) return null;
        nextPoll = now + 1;
        try
        {
            Stamp current = ReadStamp(sourceCore);
            if (current == loaded) { pending = null; lastError = null; return null; }
            if (pending != current) { pending = current; return null; }
            loaded = CopyCore();
            pending = null;
            lastError = null;
            return null;
        }
        catch (Exception error) when (error is IOException || error is UnauthorizedAccessException)
        {
            if (lastError == error.Message) return null;
            lastError = error.Message;
            return lastError;
        }
    }

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        if (directory == null) return;
        try { Directory.Delete(directory, recursive: true); }
        catch (IOException) { /* A mapped DLL may remain until the process exits. */ }
        catch (UnauthorizedAccessException) { }
    }
}
