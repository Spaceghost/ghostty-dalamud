using System;
using System.IO;
using System.Text.Json;
using Dalamud.Plugin;

namespace GhosttyDalamud.PhoneModules;

internal static class ModuleConfiguration
{
    private static readonly JsonSerializerOptions Json = new() { WriteIndented = true, IncludeFields = true };
    private static string PathFor(IDalamudPluginInterface pi, string module) =>
        Path.Combine(pi.ConfigDirectory.FullName, "phone", module + ".json");

    internal static T Load<T>(IDalamudPluginInterface pi, string module) where T : new()
    {
        string path = PathFor(pi, module);
        if (!File.Exists(path))
            path = Path.Combine(pi.ConfigDirectory.Parent!.FullName, (module == "Grimoire" ? "XivSpell" : module) + ".json");
        if (!File.Exists(path)) return new T();
        return JsonSerializer.Deserialize<T>(File.ReadAllText(path), Json) ?? new T();
    }

    internal static void Save<T>(IDalamudPluginInterface pi, string module, T config)
    {
        string path = PathFor(pi, module);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        string pending = path + ".tmp";
        File.WriteAllText(pending, JsonSerializer.Serialize(config, Json));
        File.Move(pending, path, true);
    }
}
