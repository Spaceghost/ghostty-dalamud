using System.Text.Json;
using System.Text;

namespace XivHud.Core;

public sealed record UiSurface(string Id, string Owner, string Title, string Group, string Location,
    bool Available, bool Open, bool Focused, string Status, uint Colour = 0x7dcfff,
    string? Key = null, string? ParentKey = null, int Depth = 0, int? PanelId = null, bool MainUi = true, bool ConfigUi = true, bool StateKnown = true);

public sealed record PluginUiInfo(string InternalName, string Name, bool Loaded, bool MainUi, bool ConfigUi);

/// <summary>Shared UI discovery and search. Reading a catalog never opens, focuses or hides a surface.</summary>
public static class SurfaceCatalog
{
    public const int MaximumPanels = 256;
    public const int MaximumPlugins = 128;
    private static readonly (string Owner, string Title, string Group, uint Colour)[] Modules =
    [
        ("journal", "Journal", "Activities", 0xe0af68),
        ("character", "Character", "Character", 0xbb9af7),
        ("vitals", "Vitals", "Combat", 0x9ece6a),
        ("combat", "Combat deck", "Combat", 0xff9e64),
        ("chat", "Chat and notifications", "Communication", 0xf7768e),
        ("windows", "Floating windows", "Workspace", 0x7dcfff),
        ("inventory", "Inventory", "Character and items", 0xe0af68),
        ("crafting", "Crafting worklist", "Crafting and gathering", 0x9ece6a),
        ("hud", "Interface settings", "System", 0x7dcfff),
    ];

    public static IReadOnlyList<UiSurface> Read(IReadOnlyDictionary<string, string?> modules,
        string? ghostty, DateTimeOffset now)
    {
        var output = new List<UiSurface>();
        foreach (var module in Modules)
        {
            var entry = new UiSurface("module:" + module.Owner, module.Owner, module.Title, module.Group,
                "screen", false, false, false, "Not loaded", module.Colour);
            if (modules.TryGetValue(module.Owner, out var text))
            {
                try
                {
                    using var document = Parse(text);
                    var result = Result(document.RootElement);
                    if (String(result, "module") != module.Owner || !result.TryGetProperty("state", out var state) || state.ValueKind != JsonValueKind.Object)
                        throw new JsonException("Invalid module snapshot");
                    var stale = !result.TryGetProperty("observedAt", out var stamp) || stamp.ValueKind != JsonValueKind.String || !stamp.TryGetDateTimeOffset(out var observed)
                        || now - observed > TimeSpan.FromSeconds(10) || observed - now > TimeSpan.FromSeconds(5);
                    var window = state.TryGetProperty("window", out var w) && w.ValueKind == JsonValueKind.Object ? w : state;
                    var available = Boolean(state, "ready") && !stale;
                    var opened = module.Owner switch
                    {
                        "hud" => Boolean(state, "settingsOpen"),
                        "vitals" => Boolean(state, "enabled"),
                        _ => Boolean(window, "open"),
                    };
                    entry = entry with { Available = available, Open = opened, Focused = Boolean(window, "focused"),
                        Location = String(window, "actualMode", "screen"),
                        Status = stale ? "Status is stale" : !available ? "Unavailable" : opened ? "Open" : "Closed" };
                }
                catch (Exception e) when (e is JsonException or InvalidOperationException or FormatException)
                { entry = entry with { Status = "Status unavailable" }; }
            }
            output.Add(entry);
        }
        if (ghostty is not null)
        {
            try
            {
                using var document = Parse(ghostty);
                var result = Result(document.RootElement);
                if (!result.TryGetProperty("panels", out var panels) || panels.ValueKind != JsonValueKind.Array)
                    throw new JsonException("Missing panel list");
                var seen = new HashSet<int>();
                foreach (var panel in panels.EnumerateArray().Take(MaximumPanels))
                {
                    if (panel.ValueKind != JsonValueKind.Object || !panel.TryGetProperty("id", out var id) || id.ValueKind != JsonValueKind.Number || !id.TryGetInt32(out var number) || number < 1 || !seen.Add(number)) continue;
                    var kind = String(panel, "kind");
                    if (kind is not ("terminal" or "window" or "adopted" or "chat")) continue;
                    var source = String(panel, "agent", String(panel, "app", "World panels"));
                    var group = source;
                    var title = String(panel, "title", "Untitled panel");
                    var colour = 0x7dcfffU;
                    string? key = null, parent = null; var depth = 0;
                    if (panel.TryGetProperty("workspace", out var workspace) && workspace.ValueKind == JsonValueKind.Object)
                    {
                        group = String(workspace, "group", group); title = String(workspace, "label", title);
                        key = OptionalString(workspace, "key"); parent = OptionalString(workspace, "parent");
                        if (workspace.TryGetProperty("depth", out var d) && d.ValueKind == JsonValueKind.Number && d.TryGetInt32(out var value)) depth = Math.Clamp(value, 0, 16);
                        if (workspace.TryGetProperty("colour", out var c) && c.ValueKind == JsonValueKind.Number && c.TryGetUInt32(out var rgb)) colour = rgb & 0xffffff;
                    }
                    var view = String(panel, "view", "hidden");
                    var running = kind != "terminal" || Boolean(panel, "running");
                    output.Add(new("panel:" + number, "ghostty", title, "Workspace / " + group, view,
                        true, view is not ("min" or "hidden"), Boolean(panel, "focused"), running ? view is "min" or "hidden" ? "Hidden" : "Open" : "Job exited",
                        colour, key, parent, depth, number));
                }
            }
            catch (Exception e) when (e is JsonException or InvalidOperationException or FormatException)
            { output.Add(new("provider:ghostty", "ghostty", "World workspace", "Workspace", "", false, false, false, "Status unavailable")); }
        }
        return output.AsReadOnly();
    }

    public static IReadOnlyList<UiSurface> WithPluginUis(IEnumerable<UiSurface> surfaces, IEnumerable<PluginUiInfo> plugins)
    {
        var output = surfaces.ToList();
        var names = new HashSet<string>(StringComparer.Ordinal);
        foreach (var plugin in plugins.Take(MaximumPlugins * 4).GroupBy(x => x.InternalName, StringComparer.Ordinal)
            .Select(g => g.OrderByDescending(x => x.Loaded).ThenByDescending(x => x.MainUi || x.ConfigUi).First()).Take(MaximumPlugins))
        {
            var name = plugin.InternalName;
            if (string.IsNullOrEmpty(name) || name.Length > 128 || !name.All(c => char.IsAsciiLetterOrDigit(c) || c is '.' or '_' or '-')) continue;
            if (!names.Add(name) || !plugin.MainUi && !plugin.ConfigUi) continue;
            var module = name switch { "XivHud" => "hud", "XivHud.Journal" => "journal", "XivHud.Character" => "character", "XivHud.Vitals" => "vitals", "XivHud.Combat" => "combat", "XivHud.Chat" => "chat", "XivHud.Inventory" => "inventory", "XivHud.Crafting" => "crafting", "XivHud.Windows" => "windows", _ => null };
            if (module is not null)
            {
                if (output.Any(x => x.Id == "module:" + module && x.Available) || !plugin.Loaded) continue;
                output.RemoveAll(x => x.Id == "module:" + module);
            }
            output.Add(new("plugin:" + name, name, Clean(plugin.Name), "Mods", "plugin window",
                plugin.Loaded, false, false, plugin.Loaded ? "Available" : "Not loaded", 0xbb9af7,
                MainUi: plugin.MainUi, ConfigUi: plugin.ConfigUi, StateKnown: false));
        }
        return output.AsReadOnly();
    }

    public static IReadOnlyList<UiSurface> Search(IEnumerable<UiSurface> surfaces, string query)
    {
        var entries = surfaces.Take(MaximumPanels + MaximumPlugins + 8).ToArray();
        var words = Clean(query, 160).Split(' ', StringSplitOptions.RemoveEmptyEntries);
        var byKey = entries.Where(x => x.Key is not null).GroupBy(x => x.Key!).ToDictionary(x => x.Key, x => x.First(), StringComparer.Ordinal);
        bool Matches(UiSurface entry)
        {
            var text = $"{entry.Title} {entry.Owner} {entry.Group} {entry.Location} {entry.Status}";
            var seen = new HashSet<string>();
            var parent = entry.ParentKey;
            while (parent is not null && seen.Add(parent) && byKey.TryGetValue(parent, out var ancestor))
            { text += " " + ancestor.Title; parent = ancestor.ParentKey; }
            return words.All(w => text.Contains(w, StringComparison.OrdinalIgnoreCase));
        }
        var output = new List<UiSurface>();
        foreach (var group in entries.Where(Matches).GroupBy(x => x.Group).OrderBy(x => x.Key, StringComparer.OrdinalIgnoreCase))
        {
            var sorted = group.OrderBy(x => x.Title, StringComparer.OrdinalIgnoreCase).ThenBy(x => x.Id, StringComparer.Ordinal).ToArray();
            var keys = sorted.Where(x => x.Key is not null).Select(x => x.Key!).ToHashSet(StringComparer.Ordinal);
            var children = sorted.Where(x => x.ParentKey is not null).ToLookup(x => x.ParentKey!, StringComparer.Ordinal);
            var seen = new HashSet<string>(StringComparer.Ordinal);
            void Append(UiSurface surface)
            {
                if (!seen.Add(surface.Id)) return;
                output.Add(surface);
                if (surface.Key is not null) foreach (var child in children[surface.Key]) Append(child);
            }
            foreach (var root in sorted.Where(x => x.ParentKey is null || !keys.Contains(x.ParentKey))) Append(root);
            foreach (var orphanOrCycle in sorted) Append(orphanOrCycle);
        }
        return output.AsReadOnly();
    }

    public static string Clean(string? value, int limit = 160)
    {
        if (value is null) return "";
        var text = new StringBuilder();
        foreach (var rune in value.EnumerateRunes().Take(Math.Clamp(limit, 0, 1024)))
            text.Append(Rune.IsControl(rune) ? " " : rune.ToString());
        return text.ToString();
    }

    private static JsonDocument Parse(string? text)
    {
        if (text is null || text.Length > 262144) throw new JsonException("Snapshot size limit");
        return JsonDocument.Parse(text, new JsonDocumentOptions { MaxDepth = 24 });
    }
    private static JsonElement Result(JsonElement root)
    {
        if (root.ValueKind != JsonValueKind.Object || !root.TryGetProperty("ok", out var ok) || ok.ValueKind != JsonValueKind.True
            || !root.TryGetProperty("result", out var result) || result.ValueKind != JsonValueKind.Object) throw new JsonException("Provider unavailable");
        return result;
    }
    private static bool Boolean(JsonElement root, string key) => root.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.True;
    private static string? OptionalString(JsonElement root, string key) => root.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.String ? Clean(v.GetString()) : null;
    private static string String(JsonElement root, string key, string fallback = "") => OptionalString(root, key) is { Length: > 0 } value ? value : fallback;
}
