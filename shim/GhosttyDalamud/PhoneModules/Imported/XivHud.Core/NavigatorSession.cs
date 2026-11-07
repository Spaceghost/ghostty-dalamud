using System.Text.Json;

namespace XivHud.Core;

/// <summary>UI-thread session over snapshot/queued-command providers. No dependency on a rendering host.</summary>
public sealed class NavigatorSession(Func<string, string, string?> transport, Func<IEnumerable<PluginUiInfo>>? plugins = null)
{
    private sealed record Pending(string Provider, string? RequestId, long? GhosttyRequestId, int? PanelId, DateTimeOffset Deadline);
    private readonly List<Pending> pending = [];
    public IReadOnlyList<UiSurface> Surfaces { get; private set; } = [];
    public string Message { get; private set; } = "";
    public bool HasPending => pending.Count != 0;

    public void Refresh(DateTimeOffset now)
    {
        var modules = new Dictionary<string, string?>();
        foreach (var owner in new[] { "hud", "journal", "character", "vitals", "combat", "chat", "inventory", "crafting", "windows" }) modules[owner] = Call(owner, "{\"method\":\"status\"}");
        Surfaces = SurfaceCatalog.Read(modules, Call("ghostty", "{\"method\":\"panel.list\"}"), now);
        if (plugins is not null)
        {
            try { Surfaces = SurfaceCatalog.WithPluginUis(Surfaces, plugins()); }
            catch (Exception) { } // Existing cached/IPC surfaces remain usable during a provider reload.
        }
        for (var i = pending.Count - 1; i >= 0; i--)
        {
            var item = pending[i];
            if (item.PanelId is { } panel)
            {
                if (Surfaces.Any(x => x.PanelId == panel && x.Focused)) { Message = "Panel focused"; pending.RemoveAt(i); continue; }
            }
            if (item.GhosttyRequestId is { } ghosttyId)
            {
                if (TryResult(Call("ghostty", "{\"method\":\"window.list\"}"), out var result)
                    && result.TryGetProperty("requests", out var requests) && requests.ValueKind == JsonValueKind.Array)
                {
                    var completed = requests.EnumerateArray().FirstOrDefault(x => x.ValueKind == JsonValueKind.Object
                        && x.TryGetProperty("request", out var request) && request.ValueKind == JsonValueKind.Number && request.TryGetInt64(out var value) && value == ghosttyId);
                    if (completed.ValueKind == JsonValueKind.Object && completed.TryGetProperty("ok", out var ok) && ok.ValueKind is JsonValueKind.True or JsonValueKind.False)
                    {
                        Message = ok.ValueKind == JsonValueKind.True ? "Request applied" : "Request refused: " + SurfaceCatalog.Clean(Field(completed, "error"));
                        pending.RemoveAt(i); continue;
                    }
                }
            }
            else if (item.RequestId is { } request)
            {
                var reply = Call(item.Provider, JsonSerializer.Serialize(new { method = "request.status", @params = new { id = request } }));
                if (TryResult(reply, out var result))
                {
                    var state = Field(result, "state");
                    if (state is "applied" or "refused")
                    {
                        Message = state == "applied" ? "Request applied" : "Request refused: " + SurfaceCatalog.Clean(Field(result, "error"));
                        pending.RemoveAt(i); continue;
                    }
                }
            }
            if (now >= item.Deadline) { Message = "Request sent; completion was not confirmed. Refresh to check the surface."; pending.RemoveAt(i); }
        }
    }

    public bool Activate(string id, string action, DateTimeOffset now)
    {
        if (pending.Count >= 16) { Message = "Waiting for earlier requests"; return false; }
        var surface = Surfaces.FirstOrDefault(x => x.Id == id);
        if (surface is null) { Message = "This surface is no longer listed"; return false; }
        var requests = SurfaceActions.Create(surface, action);
        if (requests.Count == 0) { Message = "This surface or action is unavailable"; return false; }
        if (pending.Count + requests.Count > 16) { Message = "Waiting for earlier requests"; return false; }
        foreach (var request in requests)
        {
            if (!TryResult(Call(request.Provider, request.Json), out var result))
            { Message = "The mod refused the action or became unavailable"; return false; }
            if (request.Provider.StartsWith("plugin:", StringComparison.Ordinal))
            {
                if (!result.TryGetProperty("requested", out var requested) || requested.ValueKind != JsonValueKind.True)
                { Message = "The mod did not accept the window request"; return false; }
            }
            else if (request.Provider == "ghostty")
            {
                if (!result.TryGetProperty("queued", out var queued) || queued.ValueKind != JsonValueKind.True)
                { Message = "The panel focus request was not accepted"; return false; }
                if (!result.TryGetProperty("request", out var token) || token.ValueKind != JsonValueKind.Number || !token.TryGetInt64(out var ghosttyId) || ghosttyId <= 0)
                { Message = "The panel action could not be confirmed"; return false; }
                pending.Add(new(request.Provider, null, ghosttyId, request.Method == "panel.focus" ? surface.PanelId : null, now.AddSeconds(5)));
            }
            else
            {
                var requestId = Field(result, "requestId");
                if (!result.TryGetProperty("accepted", out var accepted) || accepted.ValueKind != JsonValueKind.True || requestId.Length is 0 or > 128)
                { Message = "The UI request was not accepted"; return false; }
                pending.Add(new(request.Provider, requestId, null, null, now.AddSeconds(5)));
            }
        }
        Message = action == "screen" ? "Return to screen requested" : "UI request sent";
        return true;
    }

    private string? Call(string provider, string request)
    {
        try { return transport(provider, request); }
        catch (Exception) { return null; } // Optional providers may unload independently.
    }
    private static bool TryResult(string? text, out JsonElement result)
    {
        result = default;
        if (text is null || text.Length > 262144) return false;
        try
        {
            using var document = JsonDocument.Parse(text, new JsonDocumentOptions { MaxDepth = 24 });
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object || !root.TryGetProperty("ok", out var ok) || ok.ValueKind != JsonValueKind.True || !root.TryGetProperty("result", out var value) || value.ValueKind != JsonValueKind.Object) return false;
            result = value.Clone(); return true;
        }
        catch (JsonException) { return false; }
    }
    private static string Field(JsonElement value, string name) => value.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() ?? "" : "";
}
