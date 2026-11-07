using System.Numerics;
using XivHud.Protocol;
using XivHud.Style;
using System.Diagnostics;
using XivHud.Windowing;
using XivHud.Windowing.Dalamud;
using Dalamud.Bindings.ImGui;
using Dalamud.Interface.GameFonts;
using Dalamud.Interface.ManagedFontAtlas;
using Dalamud.Interface.Textures;
using Dalamud.Interface.Utility;
using Dalamud.Plugin;
using Dalamud.Plugin.Services;
using static XivHud.Style.IllustratedStyle;

namespace XivHud.Journal;

internal sealed class JournalWindow : IDisposable
{
    private readonly WorkspaceLayout workspace = new();
    internal ScreenLayout? Layout => workspace.Current;
    internal void SetScreenLayout(ScreenLayout rect) => workspace.Queue(rect);
    internal const string WindowName = "Adventurer's Journal###XivHud.Journal";
    private readonly WindowHostRouter windowHost;
    private readonly NativeGameWindowHost nativeHost;
    private readonly Configuration config;
    private readonly Action save;
    private readonly Action<uint> nativeQuest, showMap;
    private readonly Action nativeJournal;
    private readonly IFontHandle heading, body, small;
    private readonly ITextureProvider textures;
    private string search = "", category = "All chapters";
    private int filter;
    private uint selected;
    private bool focus, settingsRequested;
    internal bool IsOpen { get; private set; }
    internal object IpcState => new
    {
        layout = Layout, open = IsOpen, requestedMode = config.NativeWindowEnabled ? "native_frame" : config.WindowHostEnabled ? "world" : "screen",
        actualMode = nativeHost.IsActive ? "native_frame" : windowHost.IsHosted ? "world" : "screen",
        placement = config.WindowHostPlacement, hostingStatus = HostingStatus, focused = IsControllerFocused,
        controller = ControllerStatus, settingsOpen = settingsRequested,
        selectedQuestId = selected, search, chapter = category, filter = filter switch { 1 => "tracked", 2 => "bookmarks", _ => "all" },
        visibleQuestIds = currentVisible.Select(q => q.Id).Take(30).ToArray(),
    };
    internal Task ShutdownTask => nativeHost.ShutdownTask;
    private float previousScale;
    private readonly Queue<JournalControllerIntent> controllerCommands = new();
    private readonly JournalSearchKeyboard searchKeyboard = new();
    private readonly JournalControllerClient controller;
    private IReadOnlyList<JournalEntry> currentEntries = [];
    private JournalEntry[] currentVisible = [];
    private bool searchRequested, closeSearch, closeSettings, revealSelection, resetReading, controllerUsed;
    private int settingFocus;
    private bool revealSetting;
    internal string ControllerStatus => controller.Phase;
    internal string HostingStatus => config.NativeWindowEnabled
        ? (windowHost.RequiresHostFocus ? "Returning from world placement…" : nativeHost.Status)
        : windowHost.Status;
    private float readingScroll;
    private enum ControllerLayer { Journey, Settings, Search }
    private ControllerLayer controllerLayer;
    internal bool IsControllerFocused { get; private set; }

    internal void ApplyControllerCommand(JournalControllerIntent intent)
    {
        if (IsOpen && IsControllerFocused && controllerCommands.Count < 32 && float.IsFinite(intent.Amount))
            controllerCommands.Enqueue(intent);
    }

    internal JournalWindow(IDalamudPluginInterface pi, Configuration config, Action save,
        Action<uint> nativeQuest, Action nativeJournal, Action<uint> showMap, ITextureProvider textures)
    {
        this.config = config; this.save = save; this.nativeQuest = nativeQuest;
        this.nativeJournal = nativeJournal; this.showMap = showMap;
        this.textures = textures;
        controller = new JournalControllerClient(pi, config);
        var call = pi.GetIpcSubscriber<string, string>(GhosttyWindowHost.CallChannel);
        var post = pi.GetIpcSubscriber<string, object>(GhosttyWindowHost.PostChannel);
        var floatingCall = pi.GetIpcSubscriber<string, string>(FloatingWindowHost.CallChannel);
        var floatingPost = pi.GetIpcSubscriber<string, object>(FloatingWindowHost.PostChannel);
        windowHost = new WindowHostRouter(new FloatingWindowHost(WindowName, "XivHud.Journal", floatingCall.InvokeFunc, floatingPost.InvokeAction),
            new GhosttyWindowHost(WindowName, "XivHud.Journal", call.InvokeFunc, post.InvokeAction));
        nativeHost = new NativeGameWindowHost(pi, WindowName, "XivHudJournal", "Journal", new(1080, 700));
        var acquired = new List<IFontHandle>();
        try
        {
            heading = pi.UiBuilder.FontAtlas.NewGameFontHandle(new GameFontStyle(GameFontFamily.Jupiter, 32)); acquired.Add(heading);
            body = pi.UiBuilder.FontAtlas.NewGameFontHandle(new GameFontStyle(GameFontFamily.Axis, 18)); acquired.Add(body);
            small = pi.UiBuilder.FontAtlas.NewGameFontHandle(new GameFontStyle(GameFontFamily.Axis, 15)); acquired.Add(small);
        }
        catch { foreach (var font in acquired) font.Dispose(); controller.Dispose(); windowHost.Dispose(); nativeHost.Dispose(); throw; }
    }

    internal void Toggle() { if (IsOpen) Close(); else Open(); }
    internal void Open(uint id = 0)
    {
        IsOpen = true; focus = true;
        if (config.WindowHostEnabled && !config.NativeWindowEnabled) windowHost.RequestInputFocus();
        if (id == 0) return;
        selected = id;
        search = ""; category = "All chapters"; filter = 0;
    }
    internal void Close()
    {
        IsOpen = false; IsControllerFocused = false;
        controller.Release(); controllerCommands.Clear();
        controllerLayer = ControllerLayer.Journey;
        searchRequested = settingsRequested = false;
    }
    internal void OpenSettings() { Open(); settingsRequested = true; }

    internal void Draw(IReadOnlyList<JournalEntry> entries, string? unavailable, bool loggedIn = false)
    {
        IsControllerFocused = false;
        windowHost.UseGhostty = config.UseGhosttyWorldWindows;
        var placement = Enum.TryParse<WindowPlacement>(config.WindowHostPlacement, out var requested) && Enum.IsDefined(requested)
            ? requested : WindowPlacement.Hud;
        var now = Stopwatch.GetTimestamp() / (double)Stopwatch.Frequency;
        try
        {
            // Release the exact world root before another provider may capture it. A
            // queued world adoption still owns the root until release is acknowledged.
            if (config.NativeWindowEnabled)
                windowHost.Update(false, IsOpen, loggedIn, now, placement);
            nativeHost.Prepare(config.NativeWindowEnabled && !windowHost.RequiresHostFocus, IsOpen, loggedIn);
            if (config.NativeWindowEnabled && nativeHost.CloseRequested) Close();
            if (nativeHost.ShouldDraw)
            {
                DrawCore(entries, unavailable);
                nativeHost.Capture();
            }
        }
        finally
        {
            if (!IsControllerFocused) controller.Release();
            windowHost.Update(config.WindowHostEnabled && !config.NativeWindowEnabled && !nativeHost.IsActive,
                IsOpen, loggedIn, now, placement);
        }
    }

    private void DrawCore(IReadOnlyList<JournalEntry> entries, string? unavailable)
    {
        if (!IsOpen) { IsControllerFocused = false; controller.Release(); return; }
        currentEntries = entries;
        var viewport = ImGui.GetMainViewport();
        var available = nativeHost.IsActive ? nativeHost.ContentSize : viewport.WorkSize - new Vector2(16);
        if (!float.IsFinite(available.X) || !float.IsFinite(available.Y) || available.X <= 0 || available.Y <= 0) return;
        var globalScale = ImGuiHelpers.GlobalScale;
        if (!float.IsFinite(globalScale) || globalScale <= 0) globalScale = 1;
        var preferredScale = float.IsFinite(config.Scale) ? Math.Clamp(config.Scale, .8f, 1.5f) : 1;
        // Explicit draw-list text and standard widgets must share one physical
        // scale. Fit the minimum layout without undoing the viewport cap.
        var displayScale = nativeHost.IsActive ? nativeHost.Scale : globalScale;
        if (!float.IsFinite(displayScale) || displayScale <= 0) displayScale = globalScale;
        var s = MathF.Min(preferredScale * displayScale, MathF.Min(available.X / 900, available.Y / 630));
        var initialSize = Vector2.Min(new(1080 * s, 700 * s), available);
        ImGui.SetNextWindowSize(initialSize, ImGuiCond.FirstUseEver);
        ImGui.SetNextWindowPos(viewport.WorkPos + viewport.WorkSize * .5f, ImGuiCond.FirstUseEver, new(.5f));
        ImGui.SetNextWindowSizeConstraints(new(900 * s, 630 * s), available);
        if (previousScale != 0 && Math.Abs(previousScale - s) > .005f)
            ImGui.SetNextWindowSize(initialSize);
        previousScale = s;
        if (focus)
        {
            if (!nativeHost.IsActive && !windowHost.RequiresHostFocus) ImGui.SetNextWindowFocus();
            focus = false;
        }
        ImGui.PushStyleVar(ImGuiStyleVar.WindowPadding, Vector2.Zero);
        ImGui.PushStyleVar(ImGuiStyleVar.WindowBorderSize, 0);
        ImGui.PushStyleVar(ImGuiStyleVar.FrameRounding, 4 * s);
        ImGui.PushStyleVar(ImGuiStyleVar.FramePadding, new Vector2(6, 4) * s);
        ImGui.PushStyleVar(ImGuiStyleVar.ItemSpacing, new Vector2(8, 4) * s);
        ImGui.PushStyleVar(ImGuiStyleVar.ScrollbarSize, 14 * s);
        ImGui.PushStyleColor(ImGuiCol.Text, V(Ivory));
        ImGui.PushStyleColor(ImGuiCol.FrameBg, V(C(14, 25, 31)));
        ImGui.PushStyleColor(ImGuiCol.PopupBg, V(Leather));
        ImGui.PushStyleColor(ImGuiCol.Border, V(Gold));
        ImGui.PushStyleColor(ImGuiCol.Header, V(C(55, 81, 84)));
        ImGui.PushStyleColor(ImGuiCol.HeaderHovered, V(C(64, 93, 96)));
        ImGui.PushStyleColor(ImGuiCol.HeaderActive, V(C(72, 104, 106)));
        ImGui.PushStyleColor(ImGuiCol.CheckMark, V(Aether));
        ImGui.PushStyleColor(ImGuiCol.SliderGrab, V(Gold));
        try
        {
            if (!config.NativeWindowEnabled && !config.WindowHostEnabled) workspace.ApplyNext();
            nativeHost.ApplyNextWindowLayout();
            var flags = ImGuiWindowFlags.NoTitleBar | ImGuiWindowFlags.NoBackground | ImGuiWindowFlags.NoScrollbar | ImGuiWindowFlags.NoScrollWithMouse | ImGuiWindowFlags.NoMove;
            if (nativeHost.IsActive && !nativeHost.AllowInput) flags |= ImGuiWindowFlags.NoMouseInputs;
            var visible = ImGui.Begin(WindowName, flags);
            ImGui.BeginDisabled(nativeHost.IsActive && !nativeHost.AllowInput);
            try
            {
                if (!visible) { IsControllerFocused = false; controller.Release(); return; }
                var ownPopup = ImGui.IsPopupOpen("Journal settings") || ImGui.IsPopupOpen("Search your journal");
                var focusOwner = nativeHost.IsActive
                    ? nativeHost.IsFocused
                    : windowHost.RequiresHostFocus ? windowHost.HasInputFocus
                    : ImGui.IsWindowFocused(ImGuiFocusedFlags.RootAndChildWindows);
                IsControllerFocused = focusOwner
                    && (!ImGui.IsPopupOpen("", ImGuiPopupFlags.AnyPopupId | ImGuiPopupFlags.AnyPopupLevel) || ownPopup);
                foreach (var intent in controller.Poll(IsControllerFocused)) ApplyControllerCommand(intent);
                if (!IsControllerFocused) controllerCommands.Clear();
                else
                {
                    currentVisible = JournalFilter.Apply(entries, search, filter, category, config.Bookmarks).ToArray();
                    while (IsOpen && controllerCommands.TryDequeue(out var intent)) HandleController(intent);
                }
                if (!IsOpen) return;
                using var bodyFont = body.Push();
                ImGui.SetWindowFontScale(s / globalScale);
                var p = ImGui.GetWindowPos(); var size = ImGui.GetWindowSize(); var d = ImGui.GetWindowDrawList();
                if (!config.NativeWindowEnabled && !config.WindowHostEnabled) workspace.Observe();
                Frame(d, p, size, s, config.Ornament);
                if (IsControllerFocused && controller.IsAvailable)
                    d.AddRect(p + new Vector2(6 * s), p + size - new Vector2(6 * s), Aether, 7 * s, ImDrawFlags.None, 2 * s);
                Header(d, p, size, s);
                if (!IsOpen) return;
                var left = p + new Vector2(30, 117) * s;
                var leftWidth = 284 * s;
                var paper = p + new Vector2(338, 117) * s;
                var paperSize = new Vector2(size.X - 368 * s, size.Y - 177 * s);
                Paper(d, paper, paperSize, s, config.DarkPaper, config.Ornament);
                DrawList(d, left, leftWidth, size.Y - 184 * s, s, entries, unavailable);
                var entry = entries.FirstOrDefault(q => q.Id == selected);
                DrawPage(d, paper, paperSize, s, entry, entries.Count, unavailable);
                DrawControllerPrompts(d, p, size, s);
                if (settingsRequested) { ImGui.OpenPopup("Journal settings"); settingsRequested = false; controllerLayer = ControllerLayer.Settings; }
                if (searchRequested) { ImGui.OpenPopup("Search your journal"); searchRequested = false; controllerLayer = ControllerLayer.Search; }
                Settings(s);
                SearchKeyboard(s);
                if (!ImGui.IsPopupOpen("Journal settings") && !ImGui.IsPopupOpen("Search your journal")) controllerLayer = ControllerLayer.Journey;
                if (IsControllerFocused && controllerLayer == ControllerLayer.Journey && ImGui.IsKeyPressed(ImGuiKey.Escape)) Close();
            }
            finally { ImGui.EndDisabled(); ImGui.End(); }
        }
        finally { ImGui.PopStyleColor(9); ImGui.PopStyleVar(6); }
    }

    private void Header(ImDrawListPtr d, Vector2 p, Vector2 size, float s)
    {
        ImGui.SetCursorScreenPos(p + new Vector2(18, 12) * s);
        ImGui.InvisibleButton("##binding-drag", new(size.X - 226 * s, 90 * s));
        if (!nativeHost.IsActive && ImGui.IsItemActive() && ImGui.IsMouseDragging(ImGuiMouseButton.Left))
            ImGui.SetWindowPos(p + ImGui.GetIO().MouseDelta);
        Compass(d, p + new Vector2(62, 58) * s, 23 * s, PaleGold);
        Text(d, p + new Vector2(105, 26) * s, "THE ADVENTURER'S", 13 * s, PaleGold, small);
        Text(d, p + new Vector2(103, 43) * s, "Journal", 39 * s, Ivory, heading);
        Text(d, p + new Vector2(272, 65) * s, "Every journey leaves a story.", 15 * s, Muted, small);
        if (Button(d, "settings", p + new Vector2(size.X - 192 * s, 38 * s), new(102 * s, 33 * s), "Appearance", s, false))
            settingsRequested = true;
        if (Button(d, "close", p + new Vector2(size.X - 72 * s, 38 * s), new(36 * s, 33 * s), "×", s, false)) Close();
        Rule(d, p + new Vector2(30, 100) * s, size.X - 60 * s, C(124, 116, 83, 150), s);
    }

    private void DrawList(ImDrawListPtr d, Vector2 p, float width, float height, float s, IReadOnlyList<JournalEntry> entries, string? unavailable)
    {
        Text(d, p + new Vector2(0, 1) * s, "YOUR JOURNEY", 13 * s, PaleGold, small);
        Text(d, p + new Vector2(width - 73 * s, s), $"{entries.Count} / 30", 13 * s, Muted, small);
        ImGui.SetCursorScreenPos(p + new Vector2(0, 29) * s);
        ImGui.SetNextItemWidth(width - 85 * s);
        ImGui.InputTextWithHint("##search-quests", "Search your quests…", ref search, 160);
        if (Button(d, "open-search-keyboard", p + new Vector2(width - 78 * s, 29 * s), new(78 * s, 32 * s), "Keyboard", s, false))
        { searchRequested = true; controllerLayer = ControllerLayer.Search; }
        var labels = new[] { "All", "Tracked", "Bookmarks" };
        for (var i = 0; i < labels.Length; i++)
        {
            if (Button(d, "filter" + i, p + new Vector2(i * (width + 6 * s) / 3, 68 * s), new((width - 12 * s) / 3, 31 * s), labels[i], s, filter == i)) filter = i;
        }
        ImGui.SetCursorScreenPos(p + new Vector2(0, 112) * s);
        ImGui.SetNextItemWidth(width);
        var categories = entries.Select(q => q.Category).Distinct().OrderBy(q => q).ToArray();
        if (category != "All chapters" && !categories.Contains(category)) category = "All chapters";
        if (nativeHost.IsActive)
        {
            // The combo is another owned popup: keep its scrolling viewport on the book.
            var anchor = p + new Vector2(0, 144) * s;
            ImGui.SetNextWindowPos(anchor);
            ImGui.SetNextWindowSizeConstraints(new(width, 0), new(width,
                MathF.Max(32 * s, nativeHost.ContentPosition.Y + nativeHost.ContentSize.Y - 18 * s - anchor.Y)));
        }
        if (ImGui.BeginCombo("##chapters", category))
        {
            try
            {
                if (ImGui.Selectable("All chapters", category == "All chapters")) category = "All chapters";
                foreach (var c in categories) if (ImGui.Selectable(c, c == category)) category = c;
            }
            finally { ImGui.EndCombo(); }
        }
        var visible = JournalFilter.Apply(entries, search, filter, category, config.Bookmarks).ToArray();
        currentVisible = visible;
        if (!visible.Any(q => q.Id == selected)) selected = visible.FirstOrDefault()?.Id ?? 0;
        ImGui.SetCursorScreenPos(p + new Vector2(0, 155) * s);
        if (ImGui.BeginChild("quest-list", new(width, Math.Max(70 * s, height - 217 * s)), false))
        {
            try
            {
                if (unavailable is not null) ImGui.TextWrapped(unavailable);
                else if (visible.Length == 0) ImGui.TextWrapped(entries.Count == 0 ? "A new chapter awaits. Accepted quests will find their place here." : "No quests on this page. Try a different search or chapter.");
                foreach (var q in visible)
                {
                    var row = ImGui.GetCursorScreenPos(); var active = selected == q.Id;
                    var rd = ImGui.GetWindowDrawList();
                    var rowWidth = Math.Max(50 * s, ImGui.GetContentRegionAvail().X);
                    var titleWidth = rowWidth - 28 * s;
                    var genre = q.Genre.ToUpperInvariant();
                    var genreWidth = rowWidth - 58 * s;
                    var titleY = Math.Max(34 * s, 21 * s + MeasureText(genre, 11 * s, small, genreWidth).Y);
                    var titleHeight = Math.Max(19 * s, MeasureText(q.Name, 19 * s, body, titleWidth).Y);
                    var rowHeight = Math.Max(95 * s, titleY + titleHeight + 33 * s);
                    if (Button(rd, "quest-" + q.Id, row, new(rowWidth, rowHeight), "", s, active,
                        controllerFocused: controller.IsAvailable && IsControllerFocused && active && controllerLayer == ControllerLayer.Journey)) SelectQuest(q.Id);
                    if (active && revealSelection) { ImGui.SetScrollHereY(.5f); revealSelection = false; }
                    rd.PushClipRect(row + new Vector2(8 * s), row + new Vector2(rowWidth - 8 * s, rowHeight - 5 * s), true);
                    try
                    {
                        Diamond(rd, row + new Vector2(17, 22) * s, 5 * s, q.ReadyToComplete ? Aether : PaleGold, q.ReadyToComplete);
                        Text(rd, row + new Vector2(30, 12) * s, genre, 11 * s, Muted, small, genreWidth);
                        Text(rd, row + new Vector2(14 * s, titleY), q.Name, 19 * s, active ? Ivory : C(207, 212, 202), body, titleWidth);
                        var status = $"Lv. {q.Level}" + (q.ReadyToComplete ? "   •   Ready to complete" : q.Tracked ? "   •   Tracked" : "");
                        Text(rd, row + new Vector2(14 * s, rowHeight - 25 * s), status, 12 * s, active ? Aether : Muted, small);
                        if (config.Bookmarks.Contains(q.Id)) Diamond(rd, row + new Vector2(rowWidth - 23 * s, 20 * s), 5 * s, PaleGold, true);
                    }
                    finally { rd.PopClipRect(); }
                    ImGui.SetCursorScreenPos(row + new Vector2(0, rowHeight + 8 * s));
                }
            }
            finally { ImGui.EndChild(); }
        }
        else ImGui.EndChild();
        var bottom = p + new Vector2(0, height - 42 * s);
        d.AddLine(bottom, bottom + new Vector2(width, 0), C(105, 104, 80, 140));
        if (Button(d, "original-journal", bottom + new Vector2(0, 11) * s, new(width, 32 * s), "Open original journal", s, false)) OpenOriginal();
    }

    private void DrawPage(ImDrawListPtr d, Vector2 p, Vector2 size, float s, JournalEntry? entry, int total, string? unavailable)
    {
        var ink = config.DarkPaper ? C(234, 226, 204) : C(54, 49, 39);
        var soft = config.DarkPaper ? C(166, 184, 179) : C(110, 96, 70);
        var edge = config.DarkPaper ? C(170, 153, 103, 130) : C(143, 112, 57, 110);
        ImGui.SetCursorScreenPos(p + new Vector2(35, 25) * s);
        ImGui.PushStyleColor(ImGuiCol.Text, V(ink));
        try
        {
            if (ImGui.BeginChild("reading-page", size - new Vector2(70, 126) * s, false))
            {
                try
                {
                    if (resetReading) { ImGui.SetScrollY(0); resetReading = false; }
                    if (readingScroll != 0) { ImGui.SetScrollY(Math.Clamp(ImGui.GetScrollY() + readingScroll * s, 0, ImGui.GetScrollMaxY())); readingScroll = 0; }
                    if (entry is null)
                    {
                        ImGui.Dummy(new(0, 30 * s));
                        using (heading.Push()) ImGui.TextWrapped("The next chapter");
                        ImGui.Spacing();
                        ImGui.TextWrapped(unavailable ?? (total == 0 ? "Your journal is ready for the road ahead. Accept a quest in Eorzea to begin." : "Choose a quest from your journey to unfold its story."));
                    }
                    else
                    {
                        using (small.Push()) { ImGui.PushStyleColor(ImGuiCol.Text, V(soft)); ImGui.TextWrapped(entry.Category.ToUpperInvariant()); ImGui.PopStyleColor(); }
                        ImGui.Dummy(new(0, 12 * s));
                        using (heading.Push()) ImGui.TextWrapped(entry.Name);
                        ImGui.Dummy(new(0, 9 * s));
                        using (small.Push())
                        {
                            ImGui.PushStyleColor(ImGuiCol.Text, V(soft));
                            ImGui.TextWrapped($"LEVEL {entry.Level}   /   {entry.Genre}");
                            ImGui.PopStyleColor();
                        }
                        if (entry.IconId != 0 && textures.GetFromGameIcon(new GameIconLookup(entry.IconId)).TryGetWrap(out var art, out _)
                            && art.Width > art.Height * 1.3f && art.Height > 0)
                        {
                            ImGui.Dummy(new(0, 15 * s));
                            var aspect = art.Width / (float)art.Height;
                            var artWidth = MathF.Min(ImGui.GetContentRegionAvail().X, 152 * s * aspect);
                            var artSize = new Vector2(artWidth, artWidth / aspect);
                            var artPos = ImGui.GetCursorScreenPos() + new Vector2((ImGui.GetContentRegionAvail().X - artWidth) / 2, 0);
                            ImGui.SetCursorScreenPos(artPos);
                            ImGui.Image(art.Handle, artSize);
                            ImGui.GetWindowDrawList().AddRect(artPos - new Vector2(3 * s), artPos + artSize + new Vector2(3 * s), edge, 2 * s);
                        }
                        ImGui.Dummy(new(0, 15 * s));
                        var rule = ImGui.GetCursorScreenPos();
                        Rule(ImGui.GetWindowDrawList(), rule + new Vector2(0, 3 * s), Math.Max(20, ImGui.GetContentRegionAvail().X), edge, s);
                        ImGui.Dummy(new(0, 25 * s));
                        if (!string.IsNullOrWhiteSpace(entry.Summary))
                        {
                            ImGui.TextWrapped(entry.Summary);
                            ImGui.Dummy(new(0, 23 * s));
                        }
                        using (small.Push())
                        {
                            ImGui.PushStyleColor(ImGuiCol.Text, V(soft));
                            ImGui.TextUnformatted(entry.ReadyToComplete ? "READY TO COMPLETE" : "YOUR NEXT STEP");
                            ImGui.PopStyleColor();
                        }
                        ImGui.Dummy(new(0, 12 * s));
                        if (entry.Objectives.Count == 0) ImGui.TextWrapped("Open quest details for the current objective.");
                        foreach (var objective in entry.Objectives)
                        {
                            var pos = ImGui.GetCursorScreenPos();
                            Diamond(ImGui.GetWindowDrawList(), pos + new Vector2(7, 11) * s, 4 * s, soft);
                            ImGui.SetCursorScreenPos(pos + new Vector2(23 * s, 0));
                            ImGui.PushTextWrapPos(ImGui.GetWindowContentRegionMax().X);
                            ImGui.TextUnformatted(objective);
                            ImGui.PopTextWrapPos();
                            ImGui.Dummy(new(0, 8 * s));
                        }
                    }
                }
                finally { ImGui.EndChild(); }
            }
            else ImGui.EndChild();
        }
        finally { ImGui.PopStyleColor(); }
        if (entry is null) return;
        var footer = p + new Vector2(35 * s, size.Y - 91 * s);
        Rule(d, footer, size.X - 70 * s, edge, s);
        var bookmark = config.Bookmarks.Contains(entry.Id);
        var available = size.X - 70 * s;
        var gap = 9 * s;
        var third = (available - gap * 2) / 3;
        if (Button(d, "quest-map", footer + new Vector2(0, 19 * s), new(third, 36 * s), "Show on map", s, true)) OpenMap(entry.Id);
        if (Button(d, "quest-details", footer + new Vector2(third + gap, 19 * s), new(third, 36 * s), "Quest details", s, false, true)) OpenDetails(entry.Id);
        if (Button(d, "bookmark", footer + new Vector2((third + gap) * 2, 19 * s), new(third, 36 * s), bookmark ? "Bookmarked" : "Bookmark", s, false, true))
        {
            ToggleBookmark(entry.Id);
        }
        Text(d, footer + new Vector2(0, 65 * s), entry.Tracked ? "Tracked in your duty list" : "An entry in your adventures", 12 * s, soft, small);
        Text(d, footer + new Vector2(available - 75 * s, 65 * s), "EORZEA", 12 * s, soft, small);
    }

    private void Settings(float s)
    {
        FitPopup(new(470 * s, 650 * s), s);
        ImGui.PushStyleVar(ImGuiStyleVar.WindowPadding, new Vector2(14 * s));
        ImGui.PushStyleVar(ImGuiStyleVar.WindowBorderSize, s);
        ImGui.PushStyleVar(ImGuiStyleVar.PopupRounding, 6 * s);
        var popup = ImGui.BeginPopup("Journal settings");
        ImGui.PopStyleVar(3);
        if (!popup) { closeSettings = false; return; }
        try
        {
            controllerLayer = ControllerLayer.Settings;
            if (closeSettings) { ImGui.CloseCurrentPopup(); closeSettings = false; controllerLayer = ControllerLayer.Journey; return; }
            ImGui.TextUnformatted("Make this journal your own"); ImGui.Separator(); ImGui.Spacing();
            var changed = false;
            var scale = config.Scale;
            if (ImGui.SliderFloat("Size", ref scale, .8f, 1.5f, "%.2f×")) { config.Scale = scale; changed = true; }
            HighlightSetting(0, s);
            var dark = config.DarkPaper;
            if (ImGui.Checkbox("Night parchment", ref dark)) { config.DarkPaper = dark; changed = true; }
            HighlightSetting(1, s);
            var ornament = config.Ornament;
            if (ImGui.Checkbox("Illuminated borders & paper detail", ref ornament)) { config.Ornament = ornament; changed = true; }
            HighlightSetting(2, s);
            var replace = config.ReplaceJournal;
            if (ImGui.Checkbox("Use when opening the game Journal", ref replace)) { config.ReplaceJournal = replace; changed = true; }
            HighlightSetting(3, s);
            var entry = config.ShowToolbarEntry;
            if (ImGui.Checkbox("Journal in server-info toolbar", ref entry)) { config.ShowToolbarEntry = entry; changed = true; }
            HighlightSetting(4, s);
            ImGui.Spacing(); ImGui.Separator(); ImGui.TextUnformatted("Controller");
            using (small.Push()) ImGui.TextWrapped(controller.Status);
            if (ImGui.Button($"Button labels: {config.ControllerLabels}", new(-1, 0))) { CycleLabels(1); changed = true; }
            HighlightSetting(5, s);
            var swap = config.SwapConfirmBack;
            if (ImGui.Checkbox("Swap confirm and back", ref swap)) { config.SwapConfirmBack = swap; changed = true; }
            HighlightSetting(6, s);
            ImGui.Spacing(); ImGui.Separator(); ImGui.TextUnformatted("Your journal window");
            if (ImGui.Button($"Window: {PresentationLabel()}", new(-1, 0))) { CyclePresentation(1); changed = true; }
            HighlightSetting(7, s);
            var useGhostty = config.UseGhosttyWorldWindows;
            if (ImGui.Checkbox("Use Ghostty world host", ref useGhostty)) { config.UseGhosttyWorldWindows = useGhostty; changed = true; }
            if (ImGui.Button($"Placement: {PlacementLabel(config.WindowHostPlacement)}", new(-1, 0))) { CyclePlacement(1); changed = true; }
            HighlightSetting(8, s);
            using (small.Push()) ImGui.TextWrapped(HostingStatus);
            if (ImGui.Button(config.NativeWindowEnabled
                    ? nativeHost.IsActive ? "Return to screen" : "Try native frame again"
                    : windowHost.IsHosted ? "Return to screen" : "Try world placement again", new(-1, 0))) HostAction();
            HighlightSetting(9, s);
            ImGui.Spacing(); ImGui.Separator(); ImGui.TextUnformatted("The roads ahead · quest tracker");
            var tracker = config.TrackerEnabled;
            if (ImGui.Checkbox("Show compact quest tracker", ref tracker)) { config.TrackerEnabled = tracker; changed = true; }
            HighlightSetting(10, s);
            var locked = config.TrackerLocked;
            if (ImGui.Checkbox("Lock tracker · pass clicks through", ref locked)) { config.TrackerLocked = locked; changed = true; }
            HighlightSetting(11, s);
            if (ImGui.Button(config.TrackerBookmarks ? "Quests: local bookmarks" : "Quests: tracked in game", new(-1, 0))) { config.TrackerBookmarks = !config.TrackerBookmarks; changed = true; }
            HighlightSetting(12, s);
            var limit = config.TrackerLimit;
            if (ImGui.SliderInt("Quest limit", ref limit, 1, 5)) { config.TrackerLimit = limit; changed = true; }
            HighlightSetting(13, s);
            using (small.Push()) ImGui.TextWrapped("Unlock to drag the tracker title or open quest pages. Shares this book's size and parchment; native quest tracking is unchanged.");
            ImGui.Spacing(); ImGui.Separator();
            using (small.Push()) ImGui.TextWrapped("The original journal remains available for completed quests, levequests and all native quest actions.");
            if (ImGui.Button("Open original journal", new(-1, 0))) { ImGui.CloseCurrentPopup(); OpenOriginal(); }
            HighlightSetting(14, s);
            if (ImGui.Button("Done", new(-1, 0))) { ImGui.CloseCurrentPopup(); controllerLayer = ControllerLayer.Journey; }
            HighlightSetting(15, s);
            var labels = JournalControllerLabels.For(config.ControllerLabels, config.SwapConfirmBack);
            using (small.Push()) ImGui.TextWrapped($"↑ ↓  Choose    ← → / {labels.Confirm}  Change    {labels.Back}  Back");
            if (IsControllerFocused && ImGui.IsKeyPressed(ImGuiKey.Escape)) { ImGui.CloseCurrentPopup(); controllerLayer = ControllerLayer.Journey; }
            if (changed) save();
        }
        finally { ImGui.EndPopup(); }
    }

    private void CycleLabels(int direction)
    {
        string[] labels = ["PlayStation", "Xbox", "Generic"];
        config.ControllerLabels = labels[(Math.Max(0, Array.IndexOf(labels, config.ControllerLabels)) + direction + labels.Length) % labels.Length];
    }
    private void CyclePlacement(int direction)
    {
        string[] modes = ["Companion", "Hud", "World", "Ground"];
        config.WindowHostPlacement = modes[(Math.Max(0, Array.IndexOf(modes, config.WindowHostPlacement)) + direction + modes.Length) % modes.Length];
    }
    private static string PlacementLabel(string? mode) => mode switch
    {
        "Hud" => "In front of the camera", "World" => "Here in the world", "Ground" => "On the ground", _ => "Beside you",
    };
    private string PresentationLabel() => config.NativeWindowEnabled ? "Native game frame" : config.WindowHostEnabled ? "World window" : "On screen";
    private void CyclePresentation(int direction)
    {
        var current = config.NativeWindowEnabled ? 2 : config.WindowHostEnabled ? 1 : 0;
        var next = (current + direction + 3) % 3;
        config.NativeWindowEnabled = next == 2;
        config.WindowHostEnabled = next == 1;
        if (next == 1) { windowHost.Retry(); windowHost.RequestInputFocus(); }
        controller.Release();
    }
    private void HostAction()
    {
        if (config.NativeWindowEnabled)
        {
            if (!nativeHost.IsActive) { nativeHost.Retry(); return; }
            config.NativeWindowEnabled = false;
            config.WindowHostEnabled = false;
            save();
        }
        else if (windowHost.IsHosted) windowHost.ReturnToScreen();
        else { config.WindowHostEnabled = true; windowHost.Retry(); windowHost.RequestInputFocus(); save(); }
    }

    private void HandleController(JournalControllerIntent intent)
    {
        controllerUsed = true;
        if (controllerLayer == ControllerLayer.Search)
        {
            switch (intent.Command)
            {
                case JournalControllerCommand.Up: searchKeyboard.Move(0, -1); break;
                case JournalControllerCommand.Down: searchKeyboard.Move(0, 1); break;
                case JournalControllerCommand.Left: searchKeyboard.Move(-1, 0); break;
                case JournalControllerCommand.Right: searchKeyboard.Move(1, 0); break;
                case JournalControllerCommand.PreviousTab: searchKeyboard.ChangePage(-1); break;
                case JournalControllerCommand.NextTab: searchKeyboard.ChangePage(1); break;
                case JournalControllerCommand.Confirm: EditSearch(searchKeyboard.Selected); break;
                case JournalControllerCommand.Bookmark: EditSearch("Backspace"); break;
                case JournalControllerCommand.NativeDetails: EditSearch("Space"); break;
                case JournalControllerCommand.Back:
                case JournalControllerCommand.Search: closeSearch = true; controllerLayer = ControllerLayer.Journey; break;
            }
            return;
        }
        if (controllerLayer == ControllerLayer.Settings)
        {
            switch (intent.Command)
            {
                case JournalControllerCommand.Up: settingFocus = Math.Max(0, settingFocus - 1); revealSetting = true; break;
                case JournalControllerCommand.Down: settingFocus = Math.Min(15, settingFocus + 1); revealSetting = true; break;
                case JournalControllerCommand.Left: AdjustSetting(-1); break;
                case JournalControllerCommand.Right: AdjustSetting(1); break;
                case JournalControllerCommand.Confirm: AdjustSetting(1, true); break;
                case JournalControllerCommand.Back:
                case JournalControllerCommand.Appearance: closeSettings = true; controllerLayer = ControllerLayer.Journey; break;
            }
            return;
        }
        switch (intent.Command)
        {
            case JournalControllerCommand.Up: MoveQuest(-1); break;
            case JournalControllerCommand.Down: MoveQuest(1); break;
            case JournalControllerCommand.Left: MoveChapter(-1); break;
            case JournalControllerCommand.Right: MoveChapter(1); break;
            case JournalControllerCommand.PreviousTab: filter = (filter + 2) % 3; RefreshVisible(); break;
            case JournalControllerCommand.NextTab: filter = (filter + 1) % 3; RefreshVisible(); break;
            case JournalControllerCommand.Scroll: readingScroll += Math.Clamp(intent.Amount, -200, 200); break;
            case JournalControllerCommand.Confirm:
                if (CurrentQuest() is { } mapEntry) OpenMap(mapEntry.Id);
                break;
            case JournalControllerCommand.Back: Close(); break;
            case JournalControllerCommand.Bookmark:
                if (CurrentQuest() is { } bookmarkEntry) { ToggleBookmark(bookmarkEntry.Id); RefreshVisible(); }
                break;
            case JournalControllerCommand.NativeDetails:
                if (CurrentQuest() is { } nativeEntry) OpenDetails(nativeEntry.Id);
                break;
            case JournalControllerCommand.Appearance: settingsRequested = true; controllerLayer = ControllerLayer.Settings; break;
            case JournalControllerCommand.Search: searchRequested = true; controllerLayer = ControllerLayer.Search; break;
        }
    }

    private JournalEntry? CurrentQuest() => currentVisible.FirstOrDefault(q => q.Id == selected);
    private void SelectQuest(uint id)
    {
        if (selected != id) { selected = id; resetReading = true; }
        revealSelection = true;
    }
    private void MoveQuest(int direction)
    {
        if (currentVisible.Length == 0) return;
        var index = Array.FindIndex(currentVisible, q => q.Id == selected);
        SelectQuest(currentVisible[Math.Clamp(index < 0 ? 0 : index + direction, 0, currentVisible.Length - 1)].Id);
    }
    private void MoveChapter(int direction)
    {
        var chapters = new[] { "All chapters" }.Concat(currentEntries.Select(q => q.Category).Distinct().OrderBy(c => c)).ToArray();
        var index = Math.Max(0, Array.IndexOf(chapters, category));
        category = chapters[(index + direction + chapters.Length) % chapters.Length];
        RefreshVisible();
    }
    private void RefreshVisible()
    {
        currentVisible = JournalFilter.Apply(currentEntries, search, filter, category, config.Bookmarks).ToArray();
        if (!currentVisible.Any(q => q.Id == selected)) SelectQuest(currentVisible.FirstOrDefault()?.Id ?? 0);
        revealSelection = true;
    }
    private void ToggleBookmark(uint id)
    {
        if (!config.Bookmarks.Remove(id)) config.Bookmarks.Add(id);
        save();
    }
    private void OpenMap(uint id) { Close(); showMap(id); }
    private void OpenDetails(uint id) { Close(); nativeQuest(id); }
    private void OpenOriginal() { Close(); nativeJournal(); }

    private void AdjustSetting(int direction, bool activate = false)
    {
        switch (settingFocus)
        {
            case 0: config.Scale = Math.Clamp(MathF.Round((config.Scale + direction * .05f) * 20) / 20, .8f, 1.5f); break;
            case 1: config.DarkPaper = !config.DarkPaper; break;
            case 2: config.Ornament = !config.Ornament; break;
            case 3: config.ReplaceJournal = !config.ReplaceJournal; break;
            case 4: config.ShowToolbarEntry = !config.ShowToolbarEntry; break;
            case 5: CycleLabels(direction); break;
            case 6: config.SwapConfirmBack = !config.SwapConfirmBack; break;
            case 7: CyclePresentation(direction); break;
            case 8: CyclePlacement(direction); break;
            case 9: if (activate) HostAction(); return;
            case 10: config.TrackerEnabled = !config.TrackerEnabled; break;
            case 11: config.TrackerLocked = !config.TrackerLocked; break;
            case 12: config.TrackerBookmarks = !config.TrackerBookmarks; break;
            case 13: config.TrackerLimit = Math.Clamp(config.TrackerLimit + direction, 1, 5); break;
            case 14: if (activate) OpenOriginal(); return;
            case 15: if (activate) { closeSettings = true; controllerLayer = ControllerLayer.Journey; } return;
        }
        save();
    }

    private void DrawControllerPrompts(ImDrawListPtr d, Vector2 p, Vector2 size, float s)
    {
        if (controller.IsAvailable || controllerUsed)
        {
            var color = IsControllerFocused ? PaleGold : Muted;
            var labels = JournalControllerLabels.For(config.ControllerLabels, config.SwapConfirmBack);
            Text(d, p + new Vector2(54 * s, size.Y - 45 * s),
                controller.Phase == "WaitingForNeutral" ? "Release controller buttons to focus this journal."
                    : $"D-pad / LS  Quests     ← →  Chapters     {labels.Tabs}  Tabs     RS  Read", 12 * s, color, small);
            Text(d, p + new Vector2(54 * s, size.Y - 27 * s),
                $"{labels.Confirm}  Map     {labels.Back}  Back     {labels.Bookmark}  Bookmark     {labels.Details}  Details     {labels.Appearance}  Appearance     {labels.Search}  Search", 12 * s, color, small);
        }
        else
        {
            Text(d, p + new Vector2(54 * s, size.Y - 45 * s), "Controller navigation is unavailable. Appearance has connection details.", 12 * s, Muted, small);
            Text(d, p + new Vector2(54 * s, size.Y - 27 * s), "Esc  Close    •    Drag the binding to move", 12 * s, Muted, small);
        }
    }

    private void EditSearch(string key)
    {
        if (key == "Done") { closeSearch = true; controllerLayer = ControllerLayer.Journey; }
        else { search = JournalSearchKeyboard.Edit(search, key); RefreshVisible(); }
    }

    private void SearchKeyboard(float s)
    {
        FitPopup(new(620 * s, 370 * s), s);
        ImGui.PushStyleVar(ImGuiStyleVar.WindowPadding, new Vector2(18 * s));
        ImGui.PushStyleVar(ImGuiStyleVar.WindowBorderSize, s);
        ImGui.PushStyleVar(ImGuiStyleVar.PopupRounding, 6 * s);
        var popup = ImGui.BeginPopup("Search your journal");
        ImGui.PopStyleVar(3);
        if (!popup) { closeSearch = false; return; }
        try
        {
            controllerLayer = ControllerLayer.Search;
            if (closeSearch) { ImGui.CloseCurrentPopup(); closeSearch = false; controllerLayer = ControllerLayer.Journey; return; }
            ImGui.TextUnformatted("Search your journey");
            ImGui.Spacing();
            ImGui.SetNextItemWidth(-1);
            if (ImGui.InputTextWithHint("##controller-search", "Quest, place or objective…", ref search, 160)) RefreshVisible();
            ImGui.Spacing();
            var d = ImGui.GetWindowDrawList();
            var width = ImGui.GetContentRegionAvail().X;
            var start = ImGui.GetCursorScreenPos();
            for (var row = 0; row < searchKeyboard.Rows.Count; row++)
            {
                var keys = searchKeyboard.Rows[row];
                var keyWidth = (width - (keys.Length - 1) * 5 * s) / keys.Length;
                for (var col = 0; col < keys.Length; col++)
                {
                    var selectedKey = searchKeyboard.Row == row && searchKeyboard.Column == col;
                    var pos = start + new Vector2(col * (keyWidth + 5 * s), row * 43 * s);
                    if (Button(d, $"keyboard-{row}-{col}", pos, new(keyWidth, 37 * s), keys[col], s, selectedKey,
                        controllerFocused: IsControllerFocused && selectedKey))
                    {
                        searchKeyboard.Select(row, col);
                        EditSearch(keys[col]);
                    }
                }
            }
            ImGui.SetCursorScreenPos(start + new Vector2(0, searchKeyboard.Rows.Count * 43 * s));
            var labels = JournalControllerLabels.For(config.ControllerLabels, config.SwapConfirmBack);
            if (ImGui.Button(searchKeyboard.Page == 0 ? $"Numbers & accents  ({labels.Tabs})" : $"Letters  ({labels.Tabs})")) searchKeyboard.ChangePage(1);
            ImGui.Spacing();
            using (small.Push()) ImGui.TextWrapped($"Arrows: choose key   {labels.Confirm}: type   {labels.Bookmark}: erase   {labels.Details}: space   {labels.Back}: done");
            if (IsControllerFocused && ImGui.IsKeyPressed(ImGuiKey.Escape)) { ImGui.CloseCurrentPopup(); controllerLayer = ControllerLayer.Journey; }
        }
        finally { ImGui.EndPopup(); }
    }

    private static void FitPopup(Vector2 preferred, float scale)
    {
        var rectangle = JournalPopupLayout.Fit(ImGui.GetWindowPos(), ImGui.GetWindowSize(), preferred, scale);
        ImGui.SetNextWindowPos(rectangle.Position);
        ImGui.SetNextWindowSize(rectangle.Size);
        ImGui.SetNextWindowSizeConstraints(rectangle.Size, rectangle.Size);
    }

    private void HighlightSetting(int index, float s)
    {
        if (!IsControllerFocused || !controller.IsAvailable || controllerLayer != ControllerLayer.Settings || settingFocus != index) return;
        if (revealSetting) { ImGui.SetScrollHereY(.5f); revealSetting = false; }
        ImGui.GetWindowDrawList().AddRect(ImGui.GetItemRectMin() - new Vector2(3 * s),
            ImGui.GetItemRectMax() + new Vector2(3 * s), Aether, 4 * s, ImDrawFlags.None, 2 * s);
    }

    private bool Button(ImDrawListPtr d, string id, Vector2 p, Vector2 size, string text, float s, bool active, bool onPaper = false, bool controllerFocused = false)
    {
        ImGui.SetCursorScreenPos(p);
        ImGui.PushStyleColor(ImGuiCol.Button, Vector4.Zero);
        ImGui.PushStyleColor(ImGuiCol.ButtonHovered, Vector4.Zero);
        ImGui.PushStyleColor(ImGuiCol.ButtonActive, Vector4.Zero);
        bool clicked;
        try { clicked = ImGui.Button("##" + id, size); }
        finally { ImGui.PopStyleColor(3); }
        var hovered = ImGui.IsItemHovered();
        var focused = ImGui.IsItemFocused() || controllerFocused;
        var bg = active ? C(48, 78, 80) : onPaper ? (config.DarkPaper ? C(53, 68, 67) : C(196, 178, 136, 90)) : C(21, 35, 41);
        if (hovered) bg = active ? C(64, 99, 100) : onPaper ? (config.DarkPaper ? C(70, 84, 78) : C(191, 166, 114, 145)) : C(43, 63, 67);
        d.AddRectFilled(p, p + size, bg, 4 * s);
        d.AddRect(p, p + size, active || focused ? Aether : onPaper ? C(145, 121, 74, 150) : C(119, 116, 90, 140), 4 * s, ImDrawFlags.None, focused ? 2 * s : s);
        if (text.Length > 0)
        {
            using var font = small.Push();
            var fs = 15 * s;
            var width = ImGui.CalcTextSize(text).X * (fs / ImGui.GetFontSize());
            Text(d, p + new Vector2((size.X - width) / 2, (size.Y - fs) / 2 - s), text, fs, onPaper ? (config.DarkPaper ? Ivory : C(72, 61, 42)) : Ivory, small);
        }
        return clicked;
    }

    private static void Text(ImDrawListPtr d, Vector2 p, string text, float size, uint color, IFontHandle font, float wrap = 0)
    {
        using var scoped = font.Push();
        d.AddText(ImGui.GetFont(), size, p, color, text, wrap);
    }

    private static Vector2 MeasureText(string text, float size, IFontHandle font, float wrap)
    {
        using var scoped = font.Push();
        var scale = size / ImGui.GetFontSize();
        return ImGui.CalcTextSize(text, false, wrap / scale) * scale;
    }

    public void Dispose() { controller.Dispose(); nativeHost.Dispose(); windowHost.Dispose(); heading.Dispose(); body.Dispose(); small.Dispose(); }
}

internal static class JournalFilter
{
    internal static IEnumerable<JournalEntry> Apply(IEnumerable<JournalEntry> entries, string search, int filter, string category, IReadOnlySet<uint> bookmarks)
    {
        var needle = search.Trim();
        return entries.Where(q => (filter != 1 || q.Tracked) && (filter != 2 || bookmarks.Contains(q.Id))
            && (category == "All chapters" || q.Category == category)
            && (needle.Length == 0 || q.Name.Contains(needle, StringComparison.CurrentCultureIgnoreCase)
                || q.Genre.Contains(needle, StringComparison.CurrentCultureIgnoreCase)
                || q.Objectives.Any(o => o.Contains(needle, StringComparison.CurrentCultureIgnoreCase))))
            .OrderByDescending(q => q.Priority).ThenByDescending(q => q.Tracked).ThenBy(q => q.Name, StringComparer.CurrentCultureIgnoreCase);
    }
}
