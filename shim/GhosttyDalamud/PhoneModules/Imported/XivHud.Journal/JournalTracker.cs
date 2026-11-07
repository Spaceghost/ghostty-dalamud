using System.Numerics;
using Dalamud.Bindings.ImGui;
using Dalamud.Interface.GameFonts;
using Dalamud.Interface.ManagedFontAtlas;
using Dalamud.Interface.Utility;
using Dalamud.Plugin;
using static XivHud.Style.IllustratedStyle;

namespace XivHud.Journal;

/// <summary>A passive companion to the book. No hooks, game actions or controller lease.</summary>
internal sealed class JournalTracker : IDisposable
{
    private readonly Configuration config;
    private readonly Action save;
    private readonly Action<uint> open;
    private readonly IFontHandle title, body;
    private bool dirty;
    private long lastDraw;
    internal uint[] VisibleIds { get; private set; } = [];
    internal object IpcState => new
    {
        enabled = config.TrackerEnabled, locked = config.TrackerLocked,
        filter = config.TrackerBookmarks ? "bookmarks" : "tracked", limit = config.TrackerLimit,
        visibleQuestIds = Environment.TickCount64 - lastDraw <= 500 ? VisibleIds : [],
    };

    internal JournalTracker(IDalamudPluginInterface pi, Configuration config, Action save, Action<uint> open)
    {
        this.config = config; this.save = save; this.open = open;
        title = pi.UiBuilder.FontAtlas.NewGameFontHandle(new GameFontStyle(GameFontFamily.Jupiter, 20));
        try { body = pi.UiBuilder.FontAtlas.NewGameFontHandle(new GameFontStyle(GameFontFamily.Axis, 16)); }
        catch { title.Dispose(); throw; }
    }

    internal void Draw(IReadOnlyList<JournalEntry> entries, bool fresh)
    {
        VisibleIds = [];
        if (!config.TrackerEnabled || !fresh) return;
        var selected = JournalTrackerPolicy.Select(entries, config.Bookmarks, config.TrackerBookmarks, config.TrackerLimit);
        var viewport = ImGui.GetMainViewport();
        var global = ImGuiHelpers.GlobalScale;
        if (!float.IsFinite(global) || global <= 0) global = 1;
        var available = viewport.WorkSize;
        if (available.X <= 0 || available.Y <= 0) return;
        var s = Math.Min(config.Scale * global, Math.Min(available.X / 356, available.Y / 220));
        if (!float.IsFinite(s) || s <= 0) return;
        var width = 356 * s; var textWidth = width - 64 * s;
        var rows = selected.Select(q => (Quest: q, Title: Math.Min(48 * s, Measure(q.Name, 20 * s, textWidth, title)),
            Text: Math.Min(70 * s, Measure(JournalTrackerPolicy.Objective(q), 16 * s, textWidth, body)))).ToArray();
        var height = Math.Min(available.Y, 120 * s + (rows.Length == 0 ? 55 * s : rows.Sum(r => r.Title + r.Text + 24 * s)));
        var size = new Vector2(width, height);
        var p = JournalTrackerPolicy.Position(viewport.WorkPos, available, size, config.TrackerAnchor);
        ImGui.SetNextWindowPos(p); ImGui.SetNextWindowSize(size);
        var flags = ImGuiWindowFlags.NoTitleBar | ImGuiWindowFlags.NoBackground | ImGuiWindowFlags.NoResize |
            ImGuiWindowFlags.NoMove | ImGuiWindowFlags.NoSavedSettings | ImGuiWindowFlags.NoNav |
            ImGuiWindowFlags.NoScrollbar | ImGuiWindowFlags.NoScrollWithMouse | ImGuiWindowFlags.NoFocusOnAppearing;
        if (config.TrackerLocked) flags |= ImGuiWindowFlags.NoInputs;
        ImGui.PushStyleVar(ImGuiStyleVar.WindowPadding, Vector2.Zero);
        ImGui.PushStyleVar(ImGuiStyleVar.WindowBorderSize, 0);
        try
        {
            var visible = ImGui.Begin("The roads ahead###XivHud.Journal.Tracker", flags);
            try
            {
                if (!visible) return;
                lastDraw = Environment.TickCount64;
                var d = ImGui.GetWindowDrawList();
                Frame(d, p, size, s, config.Ornament);
                Compass(d, p + new Vector2(28, 28) * s, 11 * s, PaleGold);
                Text(d, p + new Vector2(48, 16) * s, "The roads ahead", 23 * s, Ivory, title, width - 65 * s, 30 * s);
                Text(d, p + new Vector2(22, 48) * s, (config.TrackerBookmarks ? "BOOKMARKS" : "TRACKED QUESTS") + (config.TrackerLocked ? "" : " · DRAG TITLE TO MOVE"), 11 * s, PaleGold, body, width - 44 * s, 17 * s);
                var paper = p + new Vector2(16, 70) * s;
                Paper(d, paper, new(width - 32 * s, height - 99 * s), s, config.DarkPaper, config.Ornament);
                var ink = config.DarkPaper ? Ivory : Ink;
                var soft = config.DarkPaper ? Muted : C(108, 94, 67);
                var y = p.Y + 83 * s;
                if (rows.Length == 0)
                    Text(d, new(p.X + 30 * s, y), config.TrackerBookmarks ? "Bookmark accepted quests in your Journal." : "Track a quest in the original Journal.", 16 * s, soft, body, textWidth, 50 * s);
                var drawn = new List<uint>();
                foreach (var row in rows)
                {
                    var rowHeight = row.Title + row.Text + 24 * s;
                    if (y + rowHeight > p.Y + height - 30 * s) break;
                    var start = new Vector2(p.X + 32 * s, y);
                    if (row.Quest.Priority) Diamond(d, start - new Vector2(8 * s, -11 * s), 3 * s, Gold, true);
                    Text(d, start, row.Quest.Name, 20 * s, ink, title, textWidth, row.Title);
                    Text(d, start + new Vector2(0, row.Title + 4 * s), JournalTrackerPolicy.Objective(row.Quest), 16 * s,
                        row.Quest.ReadyToComplete ? config.DarkPaper ? Aether : C(44, 106, 99) : soft, body, textWidth, row.Text);
                    if (!config.TrackerLocked)
                    {
                        ImGui.SetCursorScreenPos(start);
                        if (ImGui.InvisibleButton("quest-" + row.Quest.Id, new(textWidth, rowHeight - 6 * s))) open(row.Quest.Id);
                        if (ImGui.IsItemHovered()) ImGui.SetTooltip("Open this quest in the illustrated Journal.");
                    }
                    drawn.Add(row.Quest.Id); y += rowHeight;
                }
                VisibleIds = drawn.ToArray();
                var footer = drawn.Count < rows.Length ? $"{rows.Length - drawn.Count} more · /xivjournal" : "/xivjournal · your full quest book";
                Text(d, p + new Vector2(22 * s, height - 23 * s), footer, 11 * s, Muted, body, width - 44 * s, 16 * s);
                if (!config.TrackerLocked)
                {
                    ImGui.SetCursorScreenPos(p); ImGui.InvisibleButton("##drag", new(width, 66 * s));
                    if (ImGui.IsItemActive() && ImGui.IsMouseDragging(ImGuiMouseButton.Left))
                    {
                        config.TrackerAnchor = JournalTrackerPolicy.FromPosition(p + ImGui.GetIO().MouseDelta, viewport.WorkPos, available, size);
                        dirty = true;
                    }
                }
                if (dirty && !ImGui.IsMouseDown(ImGuiMouseButton.Left)) { dirty = false; save(); }
            }
            finally { ImGui.End(); }
        }
        finally { ImGui.PopStyleVar(2); }
    }

    private static float Measure(string text, float size, float width, IFontHandle font)
    {
        using var scoped = font.Push();
        var factor = size / ImGui.GetFontSize();
        return ImGui.CalcTextSize(text, false, width / factor).Y * factor;
    }

    private static void Text(ImDrawListPtr d, Vector2 p, string text, float size, uint color, IFontHandle font, float width, float height)
    {
        using var scoped = font.Push();
        d.PushClipRect(p, p + new Vector2(width, height), true);
        try { d.AddText(ImGui.GetFont(), size, p, color, text, width); }
        finally { d.PopClipRect(); }
    }

    public void Dispose() { title.Dispose(); body.Dispose(); }
}
