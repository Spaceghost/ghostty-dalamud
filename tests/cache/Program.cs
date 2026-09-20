using GhosttyDalamud;

static void Check(bool value, string message)
{
    if (!value) throw new Exception(message);
}

// Release packages ship without the developer loader: the installed core is
// loaded in place, nothing is cached or polled, and a missing core is an error
// before startup rather than a crash after it.
{
    string releaseRoot = Path.Combine(Path.GetTempPath(), "ghostty-cache-test-" + Guid.NewGuid().ToString("N"));
    string releaseInstall = Path.Combine(releaseRoot, "install");
    string releaseConfig = Path.Combine(releaseRoot, "config");
    Directory.CreateDirectory(releaseInstall);
    string releaseCore = Path.Combine(releaseInstall, "ghostty_core.dll");
    File.WriteAllText(releaseCore, "core-one");
    try
    {
        using (var direct = new NativeCache(releaseInstall, releaseConfig))
        {
            Check(!direct.HotReloadEnabled, "Release must not require a loader");
            Check(direct.CorePath == releaseCore, "Release loads its installed core directly");
            Check(!Directory.Exists(releaseConfig), "Release must not write a cache");
            File.Delete(releaseCore);
            Check(direct.Refresh(1) == null, "Release must not poll or rewrite the native DLL");
        }
        Check(Directory.Exists(releaseInstall), "Release disposal must not delete the installation");
        bool missingRejected = false;
        try { using var missing = new NativeCache(releaseInstall, releaseConfig); }
        catch (FileNotFoundException) { missingRejected = true; }
        Check(missingRejected, "A missing core must be reported before startup");
    }
    finally { Directory.Delete(releaseRoot, recursive: true); }
}

// Developer builds ship the loader: every instance stages its own writable copy.
string root = Path.Combine(Path.GetTempPath(), "ghostty-cache-test-" + Guid.NewGuid().ToString("N"));
string install = Path.Combine(root, "read-only install");
string config = Path.Combine(root, "user config");
Directory.CreateDirectory(install);
Directory.CreateDirectory(config);
string source = Path.Combine(install, "ghostty_core.dll");
string loader = Path.Combine(install, "ghostty_loader.dll");
File.WriteAllText(source, "core-version-one");
File.WriteAllText(loader, "loader-fixture");
File.SetAttributes(source, FileAttributes.ReadOnly);
File.SetAttributes(loader, FileAttributes.ReadOnly);
try
{
    using var first = new NativeCache(install, config);
    Check(first.HotReloadEnabled, "Development hot reload must remain available");
    using var second = new NativeCache(install, config);
    string firstDirectory = Path.GetDirectoryName(first.CorePath)!;
    string secondDirectory = Path.GetDirectoryName(second.CorePath)!;
    Check(firstDirectory != secondDirectory, "Each instance needs its own directory");
    Check(firstDirectory != install, "Do not stage live code beside the installed DLL");
    Check(File.ReadAllText(first.CorePath) == "core-version-one", "Initial staging");
    Check(Directory.GetFiles(install).Length == 2, "Installation remains untouched");

    File.SetAttributes(source, FileAttributes.Normal);
    File.WriteAllText(source, "core-version-two-with-new-size");
    File.SetLastWriteTimeUtc(source, DateTime.UtcNow.AddSeconds(5));
    first.Refresh(10);
    Check(File.ReadAllText(first.CorePath) == "core-version-one", "First observation must settle");
    first.Refresh(11);
    Check(File.ReadAllText(first.CorePath) == "core-version-two-with-new-size", "Settled change stages");
    Check(File.ReadAllText(second.CorePath) == "core-version-one", "Other instances remain independent");

    File.Delete(source);
    Check(first.Refresh(12) != null, "Missing source should be reported");
    Check(File.ReadAllText(first.CorePath) == "core-version-two-with-new-size", "Failure preserves the cached file");
    Check(first.Refresh(13) == null, "Repeated error is not logged every frame");
    File.WriteAllText(source, "core-version-three");
    first.Refresh(14);
    first.Refresh(15);
    Check(File.ReadAllText(first.CorePath) == "core-version-three", "Recovery after source returns");

    first.Dispose();
    Check(!Directory.Exists(firstDirectory), "Dispose removes only its own cache");
    Check(Directory.Exists(secondDirectory), "Do not remove another instance's cache");
    Check(File.Exists(source), "Do not remove installation files");
    Console.WriteLine("Native cache file-isolation tests passed; no game or native DLL is loaded by this test.");
}
finally
{
    if (File.Exists(source)) File.SetAttributes(source, FileAttributes.Normal);
    File.SetAttributes(loader, FileAttributes.Normal);
    Directory.Delete(root, recursive: true);
}
