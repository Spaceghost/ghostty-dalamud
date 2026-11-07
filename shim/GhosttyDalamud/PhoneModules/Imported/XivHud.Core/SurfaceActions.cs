using System.Text.Json;

namespace XivHud.Core;

public sealed record SurfaceRequest(string Provider, string Method, string Json);

/// <summary>Explicit UI-only intents. No shell commands, walk-up requests or game actions.</summary>
public static class SurfaceActions
{
    public static IReadOnlyList<SurfaceRequest> Create(UiSurface surface, string action)
    {
        if (!surface.Available) return [];
        static SurfaceRequest Request(string provider, string method, object? parameters = null) =>
            new(provider, method, JsonSerializer.Serialize(new { method, @params = parameters ?? new { } }));
        if (surface.Id == "plugin:" + surface.Owner)
        {
            if (action == "open" && (surface.MainUi || surface.ConfigUi)) return [Request(surface.Id, surface.MainUi ? "ui.open" : "ui.settings")];
            if (action == "settings" && surface.ConfigUi) return [Request(surface.Id, "ui.settings")];
            return [];
        }
        if (surface.Owner == "ghostty" && surface.PanelId is > 0)
        {
            if (action == "open") return [Request("ghostty", "panel.focus", new { id = surface.PanelId.Value, fly = false })];
            var pin = action switch { "companion" => "pet", "world" => "here", "hud" => "hud", "ground" => "ground", _ => null };
            return pin is null ? [] : [Request("ghostty", "panel.place", new { id = surface.PanelId.Value, pin })];
        }
        if (surface.Id != "module:" + surface.Owner || surface.Owner is not ("hud" or "journal" or "character" or "vitals" or "combat" or "chat" or "inventory" or "crafting" or "windows")) return [];
        if (action == "settings" || surface.Owner == "hud" && action == "open")
            return [Request(surface.Owner, "window.settings")];
        if (action == "open") return [Request(surface.Owner, "window.open")];
        if (surface.Owner is "journal" or "character")
        {
            if (action is "screen" or "native") return [Request(surface.Owner, "window.mode", new { mode = action == "screen" ? "screen" : "native_frame" }), Request(surface.Owner, "window.open")];
            var placement = action switch { "companion" => "Companion", "world" => "World", "hud" => "Hud", "ground" => "Ground", _ => null };
            if (placement is not null) return [Request(surface.Owner, "window.mode", new { mode = "world", placement }), Request(surface.Owner, "window.open")];
        }
        return [];
    }
}
