using System.Text.Json;

namespace XivHud.Protocol;

public sealed record HudCommand(string Method, JsonElement Parameters);

/// <summary>Pure, shared validation. No input injection, game actions, or controller leases.</summary>
public static class HudCommands
{
    public static readonly string[] Modules = ["hud", "journal", "character", "vitals", "combat", "chat", "inventory", "crafting", "windows"];
    public static readonly string[] Modes = ["screen", "native_frame", "world"];
    public static readonly string[] Placements = ["Hud", "Companion", "World", "Ground"];
    public static readonly string[] Pages = ["Equipment", "Attributes", "ClassesAndJobs", "GearSets"];

    public static string[] Methods(string module) => module switch
    {
        "hud" => ["hud.set_enabled", "window.settings", "window.close", "navigator.open", "navigator.close"],
        "journal" => ["window.open", "window.close", "window.settings", "window.layout", "window.mode", "window.original", "journal.select", "journal.bookmark", "journal.show_map", "journal.tracker"],
        "character" => ["window.open", "window.close", "window.settings", "window.layout", "window.mode", "window.original", "character.page"],
        "chat" => ["window.open", "window.close", "window.settings", "window.layout", "notification.push"],
        "combat" => ["window.open", "window.close", "window.settings", "window.layout"],
        "vitals" or "inventory" or "crafting" or "windows" => ["window.open", "window.close", "window.settings"],
        _ => [],
    };

    public static string? Validate(string module, HudCommand command)
    {
        if (!Methods(module).Contains(command.Method)) return "unsupported_method";
        var p = command.Parameters;
        if (p.ValueKind != JsonValueKind.Object) return "params_must_be_object";
        string[] fields = command.Method switch
        {
            "hud.set_enabled" => ["enabled"],
            "notification.push" => ["title", "text", "kind"],
            "window.layout" => ["x", "y", "width", "height"],
            "window.mode" => ["mode", "placement"],
            "journal.select" or "journal.show_map" => ["questId"],
            "journal.bookmark" => ["questId", "bookmarked"],
            "journal.tracker" => ["enabled", "locked", "filter", "limit"],
            "character.page" => ["page"],
            _ => [],
        };
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var field in p.EnumerateObject())
            if (!fields.Contains(field.Name) || !seen.Add(field.Name)) return "unknown_or_duplicate_parameter";
        if (command.Method == "window.layout")
        {
            foreach (var key in fields)
                if (!p.TryGetProperty(key, out var number) || number.ValueKind != JsonValueKind.Number || !number.TryGetSingle(out var value) || !float.IsFinite(value)) return "invalid_screen_layout";
            if (!ScreenLayout.Read(p).Valid) return "invalid_screen_layout";
        }
        if (command.Method == "notification.push")
        {
            if (!p.TryGetProperty("title", out var title) || title.ValueKind != JsonValueKind.String || string.IsNullOrWhiteSpace(title.GetString()) || title.GetString()!.Length > 100) return "invalid_notification_title";
            if (!p.TryGetProperty("text", out var text) || text.ValueKind != JsonValueKind.String || string.IsNullOrWhiteSpace(text.GetString()) || text.GetString()!.Length > 1000) return "invalid_notification_text";
            if (!Choice(p, "kind", ["Info", "Message", "Quest", "Error"])) return "invalid_notification_kind";
        }
        if (command.Method == "hud.set_enabled" && !Boolean(p, "enabled")) return "enabled_must_be_boolean";
        if (command.Method == "window.mode")
        {
            if (!Choice(p, "mode", Modes)) return "invalid_window_mode";
            if (p.TryGetProperty("placement", out _) && (!Choice(p, "placement", Placements) || p.GetProperty("mode").GetString() != "world"))
                return "placement_requires_world_mode";
        }
        if (command.Method == "journal.tracker")
        {
            if (!Boolean(p, "enabled")) return "enabled_must_be_boolean";
            if (p.TryGetProperty("locked", out _) && !Boolean(p, "locked")) return "locked_must_be_boolean";
            if (p.TryGetProperty("filter", out _) && !Choice(p, "filter", ["tracked", "bookmarks"])) return "invalid_tracker_filter";
            if (p.TryGetProperty("limit", out var limit) && (limit.ValueKind != JsonValueKind.Number || !limit.TryGetInt32(out var count) || count is < 1 or > 5)) return "invalid_tracker_limit";
        }
        if (command.Method.StartsWith("journal.", StringComparison.Ordinal) && command.Method != "journal.tracker")
        {
            if (!p.TryGetProperty("questId", out var id) || !id.TryGetUInt32(out var value) || value == 0) return "invalid_quest_id";
            if (command.Method == "journal.bookmark" && !Boolean(p, "bookmarked")) return "bookmarked_must_be_boolean";
        }
        if (command.Method == "character.page" && !Choice(p, "page", Pages)) return "invalid_character_page";
        return null;
    }

    private static bool Boolean(JsonElement p, string name) => p.TryGetProperty(name, out var v) && v.ValueKind is JsonValueKind.True or JsonValueKind.False;
    private static bool Choice(JsonElement p, string name, string[] choices) => p.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String && choices.Contains(v.GetString());
}
