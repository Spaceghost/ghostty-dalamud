using GhosttyDalamud;

// File-lifecycle checks against the real NativeCache class. Fixture bytes are
// not native libraries: this does not exercise LoadLibrary or game behavior.
static void Require(bool value, string message)
{
    if (!value) throw new InvalidOperationException(message);
}

string root = Path.Combine(Path.GetTempPath(), "ghostty-cache-test-" + Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(root);
try
{
    string install = Path.Combine(root, "install");
    string config = Path.Combine(root, "config");
    Directory.CreateDirectory(install);
    string core = Path.Combine(install, "ghostty_core.dll");
    File.WriteAllText(core, "core-one");
    using (var direct = new NativeCache(install, config))
    {
        Require(!direct.HotReloadEnabled, "release must not require a loader");
        Require(direct.CorePath == core, "release loads its installed core directly");
        Require(!Directory.Exists(config), "release must not write a cache");
        File.Delete(core);
        Require(direct.Refresh(1) == null, "release must not poll or rewrite the native DLL");
    }
    Require(Directory.Exists(install), "release disposal must not delete installation");
    bool missingRejected = false;
    try { using var missing = new NativeCache(install, config); }
    catch (FileNotFoundException) { missingRejected = true; }
    Require(missingRejected, "missing core must be reported before startup");
    File.WriteAllText(core, "core-one");
    File.WriteAllText(Path.Combine(install, "ghostty_loader.dll"), "loader-fixture");
    string firstPath;
    using (var first = new NativeCache(install, config))
    using (var second = new NativeCache(install, config))
    {
        firstPath = first.CorePath;
        Require(first.HotReloadEnabled, "development hot reload must remain available");
        Require(first.CorePath != second.CorePath, "instances must not share live files");
        Require(File.ReadAllText(first.CorePath) == "core-one", "development core staged");
        File.WriteAllText(core, "core-two-longer");
        first.Refresh(1);
        Require(File.ReadAllText(first.CorePath) == "core-one", "one observation must not copy a changed build");
        first.Refresh(2);
        Require(File.ReadAllText(first.CorePath) == "core-two-longer", "stable build copied");
        Require(File.ReadAllText(second.CorePath) == "core-one", "other instance remains independent");
    }
    Require(!File.Exists(firstPath), "owned cache cleaned after disposal");
    Require(File.Exists(core), "installation kept after development disposal");
    Console.WriteLine("NativeCache file-lifecycle checks passed. No native DLL was executed.");
}
finally { Directory.Delete(root, recursive: true); }
