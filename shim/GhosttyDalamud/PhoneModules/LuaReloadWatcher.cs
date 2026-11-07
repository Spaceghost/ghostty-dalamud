using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;

namespace GhosttyDalamud.PhoneModules;

// File notifications only schedule work. All game/core calls stay on Draw.
internal sealed class LuaReloadWatcher : IDisposable
{
    private readonly List<FileSystemWatcher> watchers = new();
    private long due;
    internal LuaReloadWatcher(string install, string config)
    {
        try
        {
            foreach (string home in new HashSet<string>(StringComparer.OrdinalIgnoreCase) { install, config })
            {
                string path = Path.Combine(home, "lua");
                Directory.CreateDirectory(path);
                var watcher = new FileSystemWatcher(path, "*.lua") {
                    IncludeSubdirectories = true,
                    NotifyFilter = NotifyFilters.LastWrite | NotifyFilters.FileName | NotifyFilters.Size,
                };
                watcher.Changed += Changed; watcher.Created += Changed; watcher.Deleted += Changed; watcher.Renamed += Changed;
                watcher.EnableRaisingEvents = true;
                watchers.Add(watcher);
            }
        }
        catch { Dispose(); throw; }
    }
    private void Changed(object sender, FileSystemEventArgs args) => Interlocked.Exchange(ref due, Environment.TickCount64 + 500);
    internal bool Take()
    {
        long target = Interlocked.Read(ref due);
        return target > 0 && Environment.TickCount64 >= target && Interlocked.CompareExchange(ref due, 0, target) == target;
    }
    public void Dispose()
    {
        foreach (var watcher in watchers) watcher.Dispose();
        watchers.Clear();
        Interlocked.Exchange(ref due, 0);
    }
}
