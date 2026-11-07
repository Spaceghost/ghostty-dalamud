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

namespace XivHud.Character;

internal sealed class CharacterWindow : IDisposable
{
    private readonly WorkspaceLayout workspace = new();
    internal ScreenLayout? Layout => workspace.Current;
    internal void SetScreenLayout(ScreenLayout rect) => workspace.Queue(rect);
    internal const string WindowName = "Adventurer's Record###XivHud.Character";
    private static readonly string[] PageNames = ["Equipment", "Attributes", "Classes & Jobs", "Gear Sets"];
    private readonly WindowHostRouter windowHost;
    private readonly NativeGameWindowHost nativeHost;
    private readonly Configuration config;
    private readonly Action save, nativeCharacter, armoury;
    private readonly Action<int> equip;
    private readonly IFontHandle heading, body, small;
    private readonly ITextureProvider textures;
    private readonly HashSet<(uint Icon, bool Hq)> missingIcons = [];
    private readonly int[] selection = new int[4];
    private CharacterPage page;
    private bool focus, settingsRequested;
    internal bool IsOpen { get; private set; }
    internal object IpcState => new
    {
        layout = Layout, open = IsOpen, requestedMode = config.NativeWindowEnabled ? "native_frame" : config.WindowHostEnabled ? "world" : "screen",
        actualMode = nativeHost.IsActive ? "native_frame" : windowHost.IsHosted ? "world" : "screen",
        placement = config.WindowHostPlacement, hostingStatus = HostingStatus, focused = IsControllerFocused,
        controller = ControllerStatus, settingsOpen = settingsRequested,
        page = page == CharacterPage.Jobs ? "ClassesAndJobs" : page.ToString(), selectedRow = selection[(int)page],
    };
    internal void SelectIpcPage(string name) => SetPage(name == "ClassesAndJobs" ? CharacterPage.Jobs : Enum.Parse<CharacterPage>(name));
    internal Task ShutdownTask => nativeHost.ShutdownTask;
    private float previousScale;
    private readonly Queue<CharacterControllerIntent> controllerCommands = new();
    private readonly CharacterControllerClient controller;
    private CharacterSnapshot? current;
    private bool closeSettings, revealSelection, resetScroll, resetDetail, controllerUsed;
    private int settingFocus;
    private bool revealSetting;
    private string? message;
    private long messageUntil;
    internal string ControllerStatus => controller.Phase;
    internal string HostingStatus => config.NativeWindowEnabled
        ? (windowHost.RequiresHostFocus ? "Returning from world placement…" : nativeHost.Status)
        : windowHost.Status;
    private float pageScroll;
    private enum ControllerLayer { Record, Settings }
    private ControllerLayer controllerLayer;
    internal bool IsControllerFocused { get; private set; }

    internal void ApplyControllerCommand(CharacterControllerIntent intent)
    {
        if (IsOpen && IsControllerFocused && controllerCommands.Count < 32 && float.IsFinite(intent.Amount))
            controllerCommands.Enqueue(intent);
    }

    internal CharacterWindow(IDalamudPluginInterface pi, Configuration config, Action save,
        Action nativeCharacter, Action armoury, Action<int> equip, ITextureProvider textures)
    {
        this.config = config; this.save = save; this.nativeCharacter = nativeCharacter;
        this.armoury = armoury; this.equip = equip;
        this.textures = textures;
        page = Enum.IsDefined((CharacterPage)config.LastPage) ? (CharacterPage)config.LastPage : CharacterPage.Equipment;
        controller = new CharacterControllerClient(pi, config);
        var call = pi.GetIpcSubscriber<string, string>(GhosttyWindowHost.CallChannel);
        var post = pi.GetIpcSubscriber<string, object>(GhosttyWindowHost.PostChannel);
        var floatingCall = pi.GetIpcSubscriber<string, string>(FloatingWindowHost.CallChannel);
        var floatingPost = pi.GetIpcSubscriber<string, object>(FloatingWindowHost.PostChannel);
        windowHost = new WindowHostRouter(new FloatingWindowHost(WindowName, "XivHud.Character", floatingCall.InvokeFunc, floatingPost.InvokeAction),
            new GhosttyWindowHost(WindowName, "XivHud.Character", call.InvokeFunc, post.InvokeAction));
        nativeHost = new NativeGameWindowHost(pi, WindowName, "XivHudCharacter", "Character", new(1120, 720));
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
    internal void Open()
    {
        IsOpen = true; focus = true;
        if (config.WindowHostEnabled && !config.NativeWindowEnabled) windowHost.RequestInputFocus();
    }
    internal void Close()
    {
        IsOpen = false; IsControllerFocused = false;
        controller.Release(); controllerCommands.Clear();
        controllerLayer = ControllerLayer.Record;
        settingsRequested = false;
    }
    internal void OpenSettings() { Open(); settingsRequested = true; }

    /// <summary>Result of a queued gear set change, reported on the framework thread.</summary>
    internal void ShowGearSetResult(int number, int result)
    {
        message = CharacterMath.GearSetResult(number, result);
        messageUntil = Environment.TickCount64 + (result < 0 ? 9000 : 4000);
    }

    internal void Draw(CharacterSnapshot? snapshot, string? unavailable, bool loggedIn = false)
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
                DrawCore(snapshot, unavailable);
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

    private void DrawCore(CharacterSnapshot? snapshot, string? unavailable)
    {
        if (!IsOpen) { IsControllerFocused = false; controller.Release(); return; }
        current = snapshot;
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
        var s = MathF.Min(preferredScale * displayScale, MathF.Min(available.X / 960, available.Y / 640));
        var initialSize = Vector2.Min(new(1120 * s, 720 * s), available);
        ImGui.SetNextWindowSize(initialSize, ImGuiCond.FirstUseEver);
        ImGui.SetNextWindowPos(viewport.WorkPos + viewport.WorkSize * .5f, ImGuiCond.FirstUseEver, new(.5f));
        ImGui.SetNextWindowSizeConstraints(new(960 * s, 640 * s), available);
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
                var ownPopup = ImGui.IsPopupOpen("Character settings");
                var focusOwner = nativeHost.IsActive
                    ? nativeHost.IsFocused
                    : windowHost.RequiresHostFocus ? windowHost.HasInputFocus
                    : ImGui.IsWindowFocused(ImGuiFocusedFlags.RootAndChildWindows);
                IsControllerFocused = focusOwner
                    && (!ImGui.IsPopupOpen("", ImGuiPopupFlags.AnyPopupId | ImGuiPopupFlags.AnyPopupLevel) || ownPopup);
                foreach (var intent in controller.Poll(IsControllerFocused)) ApplyControllerCommand(intent);
                if (!IsControllerFocused) controllerCommands.Clear();
                else while (IsOpen && controllerCommands.TryDequeue(out var intent)) HandleController(intent);
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
                var leftWidth = 300 * s;
                var paper = p + new Vector2(354, 117) * s;
                var paperSize = new Vector2(size.X - 384 * s, size.Y - 177 * s);
                Paper(d, paper, paperSize, s, config.DarkPaper, config.Ornament);
                DrawIdentity(d, left, leftWidth, size.Y - 184 * s, s, snapshot, unavailable);
                if (!IsOpen) return;
                DrawRecord(d, paper, paperSize, s, snapshot, unavailable);
                DrawControllerPrompts(d, p, size, s);
                if (settingsRequested) { ImGui.OpenPopup("Character settings"); settingsRequested = false; controllerLayer = ControllerLayer.Settings; }
                // Escape that closes Appearance this frame must not also close the record.
                var popupWasOpen = ImGui.IsPopupOpen("Character settings");
                Settings(s);
                if (!ImGui.IsPopupOpen("Character settings")) controllerLayer = ControllerLayer.Record;
                if (IsControllerFocused && !popupWasOpen && controllerLayer == ControllerLayer.Record && ImGui.IsKeyPressed(ImGuiKey.Escape)) Close();
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
        Text(d, p + new Vector2(103, 43) * s, "Record", 39 * s, Ivory, heading);
        Text(d, p + new Vector2(250, 65) * s, "Every road leaves its mark.", 15 * s, Muted, small);
        if (Button(d, "settings", p + new Vector2(size.X - 192 * s, 38 * s), new(102 * s, 33 * s), "Appearance", s, false))
            settingsRequested = true;
        if (Button(d, "close", p + new Vector2(size.X - 72 * s, 38 * s), new(36 * s, 33 * s), "×", s, false)) Close();
        Rule(d, p + new Vector2(30, 100) * s, size.X - 60 * s, C(124, 116, 83, 150), s);
    }

    // ---- Identity card (left column) -------------------------------------------------------

    private void DrawIdentity(ImDrawListPtr d, Vector2 p, float width, float height, float s, CharacterSnapshot? snapshot, string? unavailable)
    {
        ImGui.SetCursorScreenPos(p);
        if (ImGui.BeginChild("identity-card", new(width, Math.Max(70 * s, height - 54 * s)), false))
        {
            try
            {
                var cd = ImGui.GetWindowDrawList();
                var start = ImGui.GetCursorScreenPos();
                var w = ImGui.GetContentRegionAvail().X;
                var y = 0f;
                var center = start + new Vector2(w / 2, 47 * s);
                var job = snapshot?.Job;
                Emblem(cd, center, 43 * s, s, job?.Id ?? 0, job?.SoulCrystalIcon ?? 0, job?.Abbreviation ?? "", job is not null);
                y += 100 * s;
                if (snapshot is null)
                {
                    y += Centered(cd, start, w, y, "The record awaits", 22 * s, Ivory, heading) + 10 * s;
                    y += Centered(cd, start, w, y, unavailable ?? "Gathering your record…", 15 * s, Muted, small);
                }
                else
                {
                    var id = snapshot.Identity;
                    if (id.Title.Length > 0 && id.TitleIsPrefix) y += Centered(cd, start, w, y, id.Title, 14 * s, Muted, small) + 3 * s;
                    y += Centered(cd, start, w, y, id.Name, 27 * s, Ivory, heading) + 2 * s;
                    if (id.Title.Length > 0 && !id.TitleIsPrefix) y += Centered(cd, start, w, y, $"«{id.Title}»", 14 * s, Muted, small) + 3 * s;
                    y += 4 * s;
                    var j = snapshot.Job;
                    y += Centered(cd, start, w, y, $"Lv. {j.Level}  {j.Name}", 17 * s, PaleGold, body) + 2 * s;
                    if (j.Synced) y += Centered(cd, start, w, y, $"Level synced to {j.SyncedLevel}", 13 * s, Aether, small) + 2 * s;
                    var world = id.World.Length == 0 ? id.HomeWorld
                        : id.HomeWorld.Length == 0 || id.HomeWorld == id.World ? id.World : $"{id.World}   (home: {id.HomeWorld})";
                    if (world.Length > 0) y += Centered(cd, start, w, y, world, 13 * s, Muted, small) + 2 * s;
                    y += 10 * s;
                    var pools = snapshot.Pools;
                    if (pools.Available)
                    {
                        y += Pool(cd, start + new Vector2(0, y), w, s, "HP", pools.Hp, pools.MaxHp, C(134, 178, 104));
                        y += Pool(cd, start + new Vector2(0, y), w, s, pools.SecondaryLabel, pools.Secondary, pools.MaxSecondary,
                            pools.SecondaryLabel switch { "CP" => C(166, 124, 212), "GP" => C(98, 166, 204), _ => C(206, 120, 166) });
                    }
                    y += 6 * s;
                    // Average item level: the card's most prominent figure, framed like a seal.
                    var box = start + new Vector2(0, y);
                    cd.AddRectFilled(box, box + new Vector2(w, 70 * s), C(14, 25, 31, 200), 5 * s);
                    cd.AddRect(box, box + new Vector2(w, 70 * s), Gold, 5 * s, ImDrawFlags.None, s);
                    cd.AddRect(box + new Vector2(4 * s), box + new Vector2(w - 4 * s, 66 * s), C(70, 78, 70), 3 * s);
                    Centered(cd, start, w, y + 9 * s, "AVERAGE ITEM LEVEL", 12 * s, PaleGold, small);
                    Centered(cd, start, w, y + 25 * s, snapshot.AverageItemLevel.ToString(), 36 * s, Ivory, heading);
                    y += 84 * s;
                    var gc = id.GrandCompany.Length == 0 ? "" : id.GrandCompanyRank.Length == 0 ? id.GrandCompany : $"{id.GrandCompany}\n{id.GrandCompanyRank}";
                    (string Label, string Value)[] lines =
                    [
                        ("GRAND COMPANY", gc), ("FREE COMPANY", id.FreeCompany), ("CITY-STATE", id.CityState),
                        ("NAMEDAY", id.Nameday), ("GUARDIAN", id.Guardian),
                        ("ORIGIN", string.Join(" / ", new[] { id.Race, id.Tribe, id.Gender }.Where(v => v.Length > 0))),
                    ];
                    foreach (var (label, value) in lines)
                    {
                        if (value.Length == 0) continue;
                        Diamond(cd, start + new Vector2(5 * s, y + 8 * s), 3 * s, Gold);
                        Text(cd, start + new Vector2(15 * s, y + 1 * s), label, 11 * s, Muted, small);
                        var valueHeight = MeasureText(value, 15 * s, small, w - 107 * s).Y;
                        Text(cd, start + new Vector2(105 * s, y), value, 15 * s, Ivory, small, w - 107 * s);
                        y += Math.Max(18 * s, valueHeight) + 7 * s;
                    }
                }
                ImGui.SetCursorScreenPos(start + new Vector2(0, y));
                ImGui.Dummy(new(w, 4 * s));
            }
            finally { ImGui.EndChild(); }
        }
        else ImGui.EndChild();
        var bottom = p + new Vector2(0, height - 42 * s);
        d.AddLine(bottom, bottom + new Vector2(width, 0), C(105, 104, 80, 140));
        if (Button(d, "original-character", bottom + new Vector2(0, 11) * s, new(width, 32 * s), "Open original character window", s, false)) OpenOriginal();
    }

    private float Pool(ImDrawListPtr d, Vector2 p, float w, float s, string label, uint value, uint max, uint color)
    {
        Text(d, p, label, 12 * s, PaleGold, small);
        var figure = $"{value:N0} / {max:N0}";
        var fw = MeasureText(figure, 13 * s, small, 0).X;
        Text(d, p + new Vector2(w - fw, 0), figure, 13 * s, Ivory, small);
        var bar = p + new Vector2(0, 18 * s);
        d.AddRectFilled(bar, bar + new Vector2(w, 6 * s), C(14, 25, 31), 3 * s);
        d.AddRectFilled(bar, bar + new Vector2(w * CharacterMath.Progress(value, max), 6 * s), color, 3 * s);
        d.AddRect(bar, bar + new Vector2(w, 6 * s), C(119, 116, 90, 140), 3 * s);
        return 31 * s;
    }

    /// <summary>The job seal: the game's job icon, else the soul crystal, else the drawn abbreviation.</summary>
    private void Emblem(ImDrawListPtr d, Vector2 c, float r, float s, uint jobId, uint soulIcon, string abbreviation, bool known)
    {
        d.AddCircleFilled(c, r, C(14, 25, 31), 64);
        d.AddCircle(c, r, Gold, 64, 1.4f * s);
        d.AddCircle(c, r * .88f, C(70, 78, 70), 64, s);
        for (var i = 0; i < 4; i++)
        {
            var a = i * MathF.PI / 2;
            Diamond(d, c + new Vector2(MathF.Sin(a), MathF.Cos(a)) * r, 3.5f * s, PaleGold, true);
        }
        var icon = r * 1.3f;
        if (known && (Icon(d, CharacterMath.JobIconBase + jobId, c - new Vector2(icon / 2), new(icon)) ||
                      Icon(d, soulIcon, c - new Vector2(icon * .4f), new(icon * .8f)))) return;
        if (!known) { Compass(d, c, r * .7f, C(219, 193, 137, 120)); return; }
        var text = abbreviation.Length == 0 ? "?" : abbreviation;
        var tw = MeasureText(text, 26 * s, heading, 0);
        Text(d, c - tw / 2, text, 26 * s, PaleGold, heading);
    }

    // ---- Record pages (right parchment) ----------------------------------------------------

    private void DrawRecord(ImDrawListPtr d, Vector2 p, Vector2 size, float s, CharacterSnapshot? snapshot, string? unavailable)
    {
        var inner = size.X - 70 * s;
        var gap = 8 * s;
        var tabWidth = (inner - gap * 3) / 4;
        for (var i = 0; i < PageNames.Length; i++)
            if (Button(d, "page" + i, p + new Vector2(35 * s + i * (tabWidth + gap), 24 * s), new(tabWidth, 31 * s),
                    PageNames[i], s, (int)page == i, true)) SetPage((CharacterPage)i);
        var edge = config.DarkPaper ? C(170, 153, 103, 130) : C(143, 112, 57, 110);
        Rule(d, p + new Vector2(35 * s, 70 * s), inner, edge, s);
        var area = p + new Vector2(35, 84) * s;
        var areaSize = new Vector2(inner, size.Y - 84 * s - 104 * s);
        ImGui.SetCursorScreenPos(area);
        ImGui.PushStyleColor(ImGuiCol.Text, V(Ink()));
        try
        {
            if (snapshot is null)
            {
                Text(d, area + new Vector2(0, 30 * s), "The next page", 28 * s, Ink(), heading);
                Text(d, area + new Vector2(0, 74 * s), unavailable ?? "Gathering your record…", 17 * s, Soft(), body, inner);
            }
            else if (ImGui.BeginChild("record-" + page, page == CharacterPage.Equipment ? new(areaSize.X * .47f, areaSize.Y) : areaSize, false))
            {
                try
                {
                    if (resetScroll) { ImGui.SetScrollY(0); resetScroll = false; }
                    if (pageScroll != 0 && page != CharacterPage.Equipment)
                    { ImGui.SetScrollY(Math.Clamp(ImGui.GetScrollY() + pageScroll * s, 0, ImGui.GetScrollMaxY())); pageScroll = 0; }
                    switch (page)
                    {
                        case CharacterPage.Equipment: EquipmentList(snapshot, s); break;
                        case CharacterPage.Attributes: AttributesPage(snapshot, s); break;
                        case CharacterPage.Jobs: JobsPage(snapshot, s); break;
                        default: GearSetsPage(snapshot, s); break;
                    }
                }
                finally { ImGui.EndChild(); }
            }
            else ImGui.EndChild();
            if (snapshot is not null && page == CharacterPage.Equipment)
                EquipmentDetail(area + new Vector2(areaSize.X * .47f + 18 * s, 0), new(areaSize.X * .53f - 18 * s, areaSize.Y), s, snapshot);
        }
        finally { ImGui.PopStyleColor(); }
        Footer(d, p, size, s, snapshot);
    }

    private void Footer(ImDrawListPtr d, Vector2 p, Vector2 size, float s, CharacterSnapshot? snapshot)
    {
        var edge = config.DarkPaper ? C(170, 153, 103, 130) : C(143, 112, 57, 110);
        var footer = p + new Vector2(35 * s, size.Y - 91 * s);
        var available = size.X - 70 * s;
        Rule(d, footer, available, edge, s);
        var gap = 9 * s;
        var set = page == CharacterPage.GearSets ? SelectedGearSet(snapshot) : null;
        var count = set is null ? 2 : 3;
        var width = (available - gap * (count - 1)) / count;
        var at = footer + new Vector2(0, 19 * s);
        if (set is not null)
        {
            if (Button(d, "equip-set", at, new(width, 36 * s), $"Equip gear set {set.Number}", s, true)) Equip(set);
            at += new Vector2(width + gap, 0);
        }
        if (Button(d, "armoury", at, new(width, 36 * s), "Armoury Chest", s, page == CharacterPage.Equipment, true)) OpenArmoury();
        if (Button(d, "original-window", at + new Vector2(width + gap, 0), new(width, 36 * s), "Original window", s, false, true)) OpenOriginal();
        var note = message is not null && Environment.TickCount64 < messageUntil ? message : page switch
        {
            CharacterPage.Equipment => "Equipped as you stand. Change pieces in the Armoury Chest.",
            CharacterPage.Attributes => "Your attributes for the current class or job.",
            CharacterPage.Jobs => "Every discipline you have taken up.",
            _ => "Saved gear sets. Changing sets follows the game's own rules.",
        };
        Text(d, footer + new Vector2(0, 65 * s), note, 12 * s, Soft(), small, available - 90 * s);
        Text(d, footer + new Vector2(available - 75 * s, 65 * s), "EORZEA", 12 * s, Soft(), small);
    }

    private void EquipmentList(CharacterSnapshot snapshot, float s)
    {
        // The list child occupies the left 47% of the page; the detail is a sibling child.
        var gear = snapshot.Gear;
        ClampSelection(gear.Count);
        var start = ImGui.GetCursorScreenPos();
        var width = ImGui.GetContentRegionAvail().X;
        var rd = ImGui.GetWindowDrawList();
        var y = 0f;
        for (var k = 0; k < gear.Count; k++)
        {
            if (k == 0 || k == CharacterMath.EquipmentHalf)
            {
                Text(rd, start + new Vector2(2 * s, y + 2 * s), k == 0 ? "ARMS & ARMOUR" : "ACCESSORIES", 12 * s, Soft(), small);
                y += 22 * s;
            }
            var piece = gear[k];
            var row = start + new Vector2(0, y);
            var active = selection[0] == k;
            if (Button(rd, "slot-" + k, row, new(width, 50 * s), "", s, active, true, ControllerFocus(active)))
            { if (selection[0] != k) resetDetail = true; selection[0] = k; }
            if (active && revealSelection) { ImGui.SetScrollHereY(.5f); revealSelection = false; }
            if (active && ImGui.IsItemClicked() && ImGui.IsMouseDoubleClicked(ImGuiMouseButton.Left)) OpenArmoury();
            rd.PushClipRect(row + new Vector2(4 * s), row + new Vector2(width - 4 * s, 46 * s), true);
            try
            {
                var iconAt = row + new Vector2(7, 7) * s;
                if (piece.IsEmpty || !Icon(rd, piece.Icon, iconAt, new(36 * s), piece.HighQuality))
                    rd.AddRect(iconAt, iconAt + new Vector2(36 * s), Edge(), 3 * s);
                var textColor = RowInk(active);
                var nameWidth = width - 60 * s;
                if (piece.IsEmpty)
                {
                    Text(rd, row + new Vector2(52, 7) * s, piece.SlotName, 15 * s, RowSoft(active), small);
                    Text(rd, row + new Vector2(52, 26) * s, piece.Note.Length > 0 ? piece.Note : "Nothing equipped", 12 * s, RowSoft(active), small, nameWidth);
                }
                else
                {
                    Text(rd, row + new Vector2(52, 6) * s, piece.Name, 15 * s, textColor, small, 0);
                    var line = $"{piece.SlotName}   i{piece.ItemLevel}";
                    Text(rd, row + new Vector2(52, 27) * s, line, 12 * s, RowSoft(active), small);
                    var x = 52 * s + MeasureText(line, 12 * s, small, 0).X + 8 * s;
                    if (piece.HighQuality)
                    {
                        Text(rd, row + new Vector2(x, 27 * s), "HQ", 12 * s, Aether, small);
                        x += 24 * s;
                    }
                    var sockets = Math.Max(piece.MateriaSlots, piece.Materia.Count);
                    for (var m = 0; m < Math.Min(sockets, 5); m++)
                        Diamond(rd, row + new Vector2(x + 6 * s + m * 12 * s, 34 * s), 4 * s, m < piece.Materia.Count ? Aether : RowSoft(active), m < piece.Materia.Count);
                }
            }
            finally { rd.PopClipRect(); }
            y += 56 * s;
        }
        ImGui.SetCursorScreenPos(start + new Vector2(0, y));
        ImGui.Dummy(new(width, 2 * s));
    }

    private void EquipmentDetail(Vector2 p, Vector2 size, float s, CharacterSnapshot snapshot)
    {
        if (size.X < 40 * s || size.Y < 40 * s) return;
        ImGui.SetCursorScreenPos(p);
        if (!ImGui.BeginChild("equipment-detail", size, false)) { ImGui.EndChild(); return; }
        try
        {
            if (resetDetail) { ImGui.SetScrollY(0); resetDetail = false; }
            if (pageScroll != 0) { ImGui.SetScrollY(Math.Clamp(ImGui.GetScrollY() + pageScroll * s, 0, ImGui.GetScrollMaxY())); pageScroll = 0; }
            var d = ImGui.GetWindowDrawList();
            var start = ImGui.GetCursorScreenPos();
            var w = ImGui.GetContentRegionAvail().X - 6 * s;
            var y = 0f;
            var gear = snapshot.Gear;
            var piece = selection[0] >= 0 && selection[0] < gear.Count ? gear[selection[0]] : null;
            if (piece is null) return;
            Text(d, start, piece.SlotName.ToUpperInvariant(), 12 * s, Soft(), small);
            y += 22 * s;
            if (piece.IsEmpty)
            {
                y += Wrapped(d, start + new Vector2(0, y), "Nothing equipped", 24 * s, Ink(), heading, w) + 8 * s;
                Wrapped(d, start + new Vector2(0, y), piece.Note.Length > 0 ? piece.Note
                    : "Choose a piece in the Armoury Chest to fill this slot.", 15 * s, Soft(), small, w);
                return;
            }
            var iconAt = start + new Vector2(0, y);
            if (!Icon(d, piece.Icon, iconAt, new(52 * s), piece.HighQuality)) d.AddRect(iconAt, iconAt + new Vector2(52 * s), Edge(), 3 * s);
            d.AddRect(iconAt - new Vector2(2 * s), iconAt + new Vector2(54 * s), Edge(), 3 * s);
            var nameHeight = Wrapped(d, start + new Vector2(64 * s, y), piece.Name, 22 * s, Ink(), heading, w - 64 * s);
            var sub = piece.Category + (piece.HighQuality ? "   •   High quality" : "");
            var subHeight = Wrapped(d, start + new Vector2(64 * s, y + nameHeight + 3 * s), sub, 13 * s, Soft(), small, w - 64 * s);
            y += Math.Max(58 * s, nameHeight + subHeight + 8 * s);
            Text(d, start + new Vector2(0, y), $"Item Level {piece.ItemLevel}", 15 * s, Ink(), small);
            var levelText = $"Lv. {piece.EquipLevel}";
            Text(d, start + new Vector2(w - MeasureText(levelText, 15 * s, small, 0).X, y), levelText, 15 * s, Soft(), small);
            y += 24 * s;
            Rule(d, start + new Vector2(0, y), w, Edge(), s);
            y += 14 * s;
            // Dedicated weapon/armour figures first, as large numbers; then bonuses.
            var figures = piece.Stats.Where(stat => CharacterMath.IsPrimaryItemStat(stat.Id)).ToList();
            if (piece.Delay > 0) figures.Add(new StatValue(14, "Delay", 0));
            if (figures.Count > 0)
            {
                var columns = Math.Min(figures.Count, 3);
                var cw = w / columns;
                for (var i = 0; i < figures.Count; i++)
                {
                    var at = start + new Vector2(i % columns * cw, y + i / columns * 50 * s);
                    var f = figures[i];
                    Text(d, at, f.Name, 12 * s, Soft(), small, cw - 6 * s);
                    Text(d, at + new Vector2(0, 16 * s), f.Id == 14 ? piece.Delay.ToString("0.00") : f.Value.ToString(), 24 * s, Ink(), heading);
                }
                y += (figures.Count + columns - 1) / columns * 50 * s + 6 * s;
            }
            var bonuses = piece.Stats.Where(stat => !CharacterMath.IsPrimaryItemStat(stat.Id)).ToArray();
            if (bonuses.Length > 0)
            {
                y += Heading(d, start + new Vector2(0, y), "BONUSES", w, s);
                foreach (var b in bonuses) y += Line(d, start + new Vector2(0, y), w, s, b.Name, $"+{b.Value}", false);
                y += 8 * s;
            }
            var sockets = Math.Max(piece.MateriaSlots, piece.Materia.Count);
            if (sockets > 0)
            {
                y += Heading(d, start + new Vector2(0, y), "MATERIA", w, s);
                for (var m = 0; m < sockets; m++)
                {
                    var at = start + new Vector2(0, y);
                    if (m < piece.Materia.Count)
                    {
                        var meld = piece.Materia[m];
                        Diamond(d, at + new Vector2(6 * s, 9 * s), 5 * s, Aether, true);
                        Text(d, at + new Vector2(20 * s, 0), meld.Name, 14 * s, Ink(), small, w * .55f);
                        var value = meld.Value != 0 ? $"{meld.Stat} +{meld.Value}" : meld.Stat;
                        Text(d, at + new Vector2(w - MeasureText(value, 14 * s, small, 0).X, 0), value, 14 * s, Soft(), small);
                        y += Math.Max(20 * s, MeasureText(meld.Name, 14 * s, small, w * .55f).Y) + 4 * s;
                    }
                    else
                    {
                        Diamond(d, at + new Vector2(6 * s, 9 * s), 5 * s, Edge());
                        Text(d, at + new Vector2(20 * s, 0), "Empty materia slot", 14 * s, Soft(), small);
                        y += 22 * s;
                    }
                }
                y += 8 * s;
            }
            y += Heading(d, start + new Vector2(0, y), "CARE", w, s);
            y += Meter(d, start + new Vector2(0, y), w, s, "Condition", piece.Condition, C(134, 160, 96));
            if (piece.Collectable) y += Line(d, start + new Vector2(0, y), w, s, "Collectability", piece.Collectability.ToString(), false);
            else y += Meter(d, start + new Vector2(0, y), w, s, "Spiritbond", piece.Spiritbond, C(118, 160, 190));
            if (piece.Glamour.Length > 0 || piece.Dyes.Count > 0)
            {
                y += 8 * s;
                y += Heading(d, start + new Vector2(0, y), "APPEARANCE", w, s);
                if (piece.Glamour.Length > 0) y += Line(d, start + new Vector2(0, y), w, s, "Glamour", piece.Glamour, false);
                if (piece.Dyes.Count > 0) y += Line(d, start + new Vector2(0, y), w, s, piece.Dyes.Count > 1 ? "Dyes" : "Dye", string.Join(", ", piece.Dyes), false);
            }
            ImGui.SetCursorScreenPos(start + new Vector2(0, y));
            ImGui.Dummy(new(w, 6 * s));
        }
        finally { ImGui.EndChild(); }
    }

    private void AttributesPage(CharacterSnapshot snapshot, float s)
    {
        var sections = snapshot.Attributes;
        var rows = sections.SelectMany(section => section.Stats).ToArray();
        ClampSelection(rows.Length);
        var start = ImGui.GetCursorScreenPos();
        var gap = 26 * s;
        var cw = (ImGui.GetContentRegionAvail().X - gap) / 2;
        var d = ImGui.GetWindowDrawList();
        var split = (sections.Count + 1) / 2;
        var heights = new float[2];
        var index = 0;
        for (var i = 0; i < sections.Count; i++)
        {
            var column = i < split ? 0 : 1;
            var at = start + new Vector2(column * (cw + gap), heights[column]);
            var y = Heading(d, at, sections[i].Name.ToUpperInvariant(), cw, s);
            foreach (var stat in sections[i].Stats)
            {
                var row = at + new Vector2(0, y);
                var active = selection[1] == index;
                ImGui.SetCursorScreenPos(row);
                if (ImGui.InvisibleButton("stat-" + index, new(cw, 28 * s))) selection[1] = index;
                if (active && revealSelection) { ImGui.SetScrollHereY(.5f); revealSelection = false; }
                if (stat.Emphasis) d.AddRectFilled(row, row + new Vector2(cw, 28 * s), config.DarkPaper ? C(70, 84, 78, 120) : C(196, 178, 136, 80), 4 * s);
                if (ControllerFocus(active) || ImGui.IsItemHovered())
                    d.AddRect(row, row + new Vector2(cw, 28 * s), ControllerFocus(active) ? Aether : Edge(), 4 * s, ImDrawFlags.None, ControllerFocus(active) ? 2 * s : s);
                Diamond(d, row + new Vector2(9 * s, 14 * s), 4 * s, stat.Emphasis ? Aether : Edge(), stat.Emphasis);
                Text(d, row + new Vector2(22 * s, 5 * s), stat.Name, 15 * s, stat.Emphasis ? Ink() : Soft(), small, cw * .62f);
                var value = stat.Value.ToString("N0");
                var size = stat.Emphasis ? 19f : 16f;
                Text(d, row + new Vector2(cw - 8 * s - MeasureText(value, size * s, body, 0).X, (28 - size) / 2 * s), value, size * s, Ink(), body);
                y += 30 * s;
                index++;
            }
            heights[column] += y + 16 * s;
        }
        ImGui.SetCursorScreenPos(start + new Vector2(0, Math.Max(heights[0], heights[1])));
        ImGui.Dummy(new(2 * cw, 2 * s));
    }

    private void JobsPage(CharacterSnapshot snapshot, float s)
    {
        var jobs = snapshot.Jobs;
        ClampSelection(jobs.Count);
        var start = ImGui.GetCursorScreenPos();
        var gap = 12 * s;
        var cw = (ImGui.GetContentRegionAvail().X - gap) / 2;
        var d = ImGui.GetWindowDrawList();
        var y = 0f;
        var column = 0;
        JobSection? section = null;
        for (var i = 0; i < jobs.Count; i++)
        {
            var job = jobs[i];
            if (job.Section != section)
            {
                if (column != 0) { y += 60 * s; column = 0; }
                section = job.Section;
                y += Heading(d, start + new Vector2(0, y), CharacterMath.SectionName(job.Section).ToUpperInvariant(), cw * 2 + gap, s);
            }
            var row = start + new Vector2(column * (cw + gap), y);
            var active = selection[2] == i;
            if (Button(d, "job-" + i, row, new(cw, 54 * s), "", s, job.Current, true, ControllerFocus(active))) selection[2] = i;
            if (active && revealSelection) { ImGui.SetScrollHereY(.5f); revealSelection = false; }
            d.PushClipRect(row, row + new Vector2(cw, 54 * s), true);
            try
            {
                var muted = job.Locked;
                var iconAt = row + new Vector2(8, 9) * s;
                if (!JobIcon(d, job.Id, job.SoulCrystalIcon, iconAt, 34 * s, muted))
                    Text(d, iconAt + new Vector2(0, 9 * s), job.Abbreviation, 14 * s, RowSoft(job.Current), small);
                var ink = muted ? RowSoft(job.Current) : RowInk(job.Current);
                Text(d, row + new Vector2(52, 6) * s, job.Name, 15 * s, ink, small);
                var level = job.Locked ? "—" : job.Level.ToString();
                Text(d, row + new Vector2(cw - 10 * s - MeasureText(level, 19 * s, body, 0).X, 5 * s), level, 19 * s, ink, body);
                var detail = job.Locked ? "Not yet begun" : job.Max ? "MAX" :
                    $"{job.Experience:N0} / {job.ExperienceToNext:N0}";
                Text(d, row + new Vector2(52, 26) * s, detail, 12 * s, job.Current ? Aether : Soft(), small);
                if (!job.Locked)
                {
                    var bar = row + new Vector2(52 * s, 45 * s);
                    var bw = cw - 62 * s;
                    d.AddRectFilled(bar, bar + new Vector2(bw, 3 * s), job.Current ? C(14, 25, 31, 160) : Edge(), 2 * s);
                    d.AddRectFilled(bar, bar + new Vector2(bw * (job.Max ? 1 : CharacterMath.Progress(job.Experience, job.ExperienceToNext)), 3 * s),
                        job.Max ? Gold : Aether, 2 * s);
                }
                if (job.Current) Diamond(d, row + new Vector2(cw - 14 * s, 44 * s), 4 * s, Aether, true);
            }
            finally { d.PopClipRect(); }
            column ^= 1;
            if (column == 0) y += 60 * s;
        }
        if (column != 0) y += 60 * s;
        ImGui.SetCursorScreenPos(start + new Vector2(0, y));
        ImGui.Dummy(new(2 * cw, 2 * s));
    }

    private void GearSetsPage(CharacterSnapshot snapshot, float s)
    {
        var sets = snapshot.GearSets;
        ClampSelection(sets.Count);
        var start = ImGui.GetCursorScreenPos();
        var w = ImGui.GetContentRegionAvail().X;
        var d = ImGui.GetWindowDrawList();
        if (sets.Count == 0)
        {
            Wrapped(d, start + new Vector2(0, 20 * s), "No gear sets saved yet", 24 * s, Ink(), heading, w);
            Wrapped(d, start + new Vector2(0, 60 * s), "Save your equipment as a gear set from the Armoury Chest or the game's gear set list.", 15 * s, Soft(), small, w);
            ImGui.Dummy(new(w, 90 * s));
            return;
        }
        var y = 0f;
        for (var i = 0; i < sets.Count; i++)
        {
            var set = sets[i];
            var row = start + new Vector2(0, y);
            var active = selection[3] == i;
            if (Button(d, "set-" + i, row, new(w, 54 * s), "", s, active, true, ControllerFocus(active))) selection[3] = i;
            if (ImGui.IsItemHovered() && ImGui.IsMouseDoubleClicked(ImGuiMouseButton.Left)) Equip(set);
            if (active && revealSelection) { ImGui.SetScrollHereY(.5f); revealSelection = false; }
            d.PushClipRect(row, row + new Vector2(w, 54 * s), true);
            try
            {
                var number = set.Number.ToString();
                Text(d, row + new Vector2(14 * s, 15 * s), number, 20 * s, RowSoft(active), heading);
                var iconAt = row + new Vector2(50, 9) * s;
                if (!JobIcon(d, set.JobId, set.SoulCrystalIcon, iconAt, 36 * s, false))
                    Text(d, iconAt + new Vector2(0, 10 * s), set.JobAbbreviation, 14 * s, RowSoft(active), small);
                var ink = RowInk(active);
                Text(d, row + new Vector2(98, 7) * s, set.Name, 17 * s, ink, body, 0);
                Text(d, row + new Vector2(98, 30) * s, set.JobAbbreviation, 12 * s, RowSoft(active), small);
                var level = $"i{set.ItemLevel}";
                Text(d, row + new Vector2(w - 14 * s - MeasureText(level, 18 * s, body, 0).X, 8 * s), level, 18 * s, ink, body);
                if (set.Current)
                {
                    var tag = "EQUIPPED";
                    var tw = MeasureText(tag, 11 * s, small, 0).X;
                    Diamond(d, row + new Vector2(w - 24 * s - tw, 36 * s), 3.5f * s, Aether, true);
                    Text(d, row + new Vector2(w - 14 * s - tw, 30 * s), tag, 11 * s, Aether, small);
                }
            }
            finally { d.PopClipRect(); }
            y += 60 * s;
        }
        ImGui.SetCursorScreenPos(start + new Vector2(0, y));
        ImGui.Dummy(new(w, 2 * s));
    }

    // ---- Settings ---------------------------------------------------------------------------

    private void Settings(float s)
    {
        FitPopup(new(470 * s, 650 * s), s);
        ImGui.PushStyleVar(ImGuiStyleVar.WindowPadding, new Vector2(14 * s));
        ImGui.PushStyleVar(ImGuiStyleVar.WindowBorderSize, s);
        ImGui.PushStyleVar(ImGuiStyleVar.PopupRounding, 6 * s);
        var popup = ImGui.BeginPopup("Character settings");
        ImGui.PopStyleVar(3);
        if (!popup) { closeSettings = false; return; }
        try
        {
            controllerLayer = ControllerLayer.Settings;
            if (closeSettings) { ImGui.CloseCurrentPopup(); closeSettings = false; controllerLayer = ControllerLayer.Record; return; }
            ImGui.TextUnformatted("Make this record your own"); ImGui.Separator(); ImGui.Spacing();
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
            var replace = config.ReplaceCharacter;
            if (ImGui.Checkbox("Use when opening the game Character window", ref replace)) { config.ReplaceCharacter = replace; changed = true; }
            HighlightSetting(3, s);
            var entry = config.ShowToolbarEntry;
            if (ImGui.Checkbox("Character in server-info toolbar", ref entry)) { config.ShowToolbarEntry = entry; changed = true; }
            HighlightSetting(4, s);
            ImGui.Spacing(); ImGui.Separator(); ImGui.TextUnformatted("Controller");
            using (small.Push()) ImGui.TextWrapped(controller.Status);
            if (ImGui.Button($"Button labels: {config.ControllerLabels}", new(-1, 0))) { CycleLabels(1); changed = true; }
            HighlightSetting(5, s);
            var swap = config.SwapConfirmBack;
            if (ImGui.Checkbox("Swap confirm and back", ref swap)) { config.SwapConfirmBack = swap; changed = true; }
            HighlightSetting(6, s);
            ImGui.Spacing(); ImGui.Separator(); ImGui.TextUnformatted("Your record window");
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
            ImGui.Spacing(); ImGui.Separator();
            using (small.Push()) ImGui.TextWrapped("The original character window remains available for the 3D preview, glamours, reputation, PvP and every native action.");
            if (ImGui.Button("Open original character window", new(-1, 0))) { ImGui.CloseCurrentPopup(); OpenOriginal(); }
            HighlightSetting(10, s);
            if (ImGui.Button("Done", new(-1, 0))) { ImGui.CloseCurrentPopup(); controllerLayer = ControllerLayer.Record; }
            HighlightSetting(11, s);
            var labels = CharacterControllerLabels.For(config.ControllerLabels, config.SwapConfirmBack);
            using (small.Push()) ImGui.TextWrapped($"↑ ↓  Choose    ← → / {labels.Confirm}  Change    {labels.Back}  Back");
            if (IsControllerFocused && ImGui.IsKeyPressed(ImGuiKey.Escape)) { ImGui.CloseCurrentPopup(); controllerLayer = ControllerLayer.Record; }
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
        var mode = config.NativeWindowEnabled ? 2 : config.WindowHostEnabled ? 1 : 0;
        var next = (mode + direction + 3) % 3;
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

    // ---- Controller -------------------------------------------------------------------------

    private void HandleController(CharacterControllerIntent intent)
    {
        controllerUsed = true;
        if (controllerLayer == ControllerLayer.Settings)
        {
            switch (intent.Command)
            {
                case CharacterControllerCommand.Up: settingFocus = Math.Max(0, settingFocus - 1); revealSetting = true; break;
                case CharacterControllerCommand.Down: settingFocus = Math.Min(11, settingFocus + 1); revealSetting = true; break;
                case CharacterControllerCommand.Left: AdjustSetting(-1); break;
                case CharacterControllerCommand.Right: AdjustSetting(1); break;
                case CharacterControllerCommand.Confirm: AdjustSetting(1, true); break;
                case CharacterControllerCommand.Back:
                case CharacterControllerCommand.Appearance: closeSettings = true; controllerLayer = ControllerLayer.Record; break;
            }
            return;
        }
        switch (intent.Command)
        {
            case CharacterControllerCommand.Up: MoveSelection(-1); break;
            case CharacterControllerCommand.Down: MoveSelection(1); break;
            case CharacterControllerCommand.Left: Jump(-1); break;
            case CharacterControllerCommand.Right: Jump(1); break;
            case CharacterControllerCommand.PreviousTab: SetPage((CharacterPage)(((int)page + 3) % 4)); break;
            case CharacterControllerCommand.NextTab: SetPage((CharacterPage)(((int)page + 1) % 4)); break;
            case CharacterControllerCommand.Scroll: pageScroll += Math.Clamp(intent.Amount, -200, 200); break;
            case CharacterControllerCommand.Confirm:
                if (page == CharacterPage.GearSets && SelectedGearSet(current) is { } set) Equip(set);
                else if (page == CharacterPage.Equipment) OpenArmoury();
                break;
            case CharacterControllerCommand.Back: Close(); break;
            case CharacterControllerCommand.Secondary:
            case CharacterControllerCommand.Armoury: OpenArmoury(); break;
            case CharacterControllerCommand.NativeDetails: OpenOriginal(); break;
            case CharacterControllerCommand.Appearance: settingsRequested = true; controllerLayer = ControllerLayer.Settings; break;
        }
    }

    private int PageCount(CharacterPage which) => current is not { } snapshot ? 0 : which switch
    {
        CharacterPage.Equipment => snapshot.Gear.Count,
        CharacterPage.Attributes => snapshot.Attributes.Sum(section => section.Stats.Count),
        CharacterPage.Jobs => snapshot.Jobs.Count,
        _ => snapshot.GearSets.Count,
    };
    private void MoveSelection(int delta)
    {
        var count = PageCount(page);
        if (count == 0) return;
        selection[(int)page] = CharacterMath.Move(selection[(int)page], delta, count);
        revealSelection = true; resetDetail |= page == CharacterPage.Equipment;
    }
    private void Jump(int direction)
    {
        if (page == CharacterPage.Equipment)
        {
            selection[0] = CharacterMath.EquipmentJump(selection[0], direction);
            revealSelection = true; resetDetail = true;
        }
        else MoveSelection(direction * 6);
    }
    private void ClampSelection(int count)
    {
        ref var index = ref selection[(int)page];
        index = count == 0 ? 0 : Math.Clamp(index, 0, count - 1);
    }
    private void SetPage(CharacterPage next)
    {
        if (page == next) return;
        page = next; resetScroll = true; revealSelection = true; pageScroll = 0;
        config.LastPage = (int)next;
        save();
    }
    private GearSetEntry? SelectedGearSet(CharacterSnapshot? snapshot) =>
        snapshot is { GearSets.Count: > 0 } ? snapshot.GearSets[Math.Clamp(selection[3], 0, snapshot.GearSets.Count - 1)] : null;
    private void Equip(GearSetEntry set)
    {
        message = $"Changing to gear set {set.Number}…";
        messageUntil = Environment.TickCount64 + 4000;
        equip(set.Id);
    }
    private void OpenArmoury() { Close(); armoury(); }
    private void OpenOriginal() { Close(); nativeCharacter(); }
    private bool ControllerFocus(bool active) =>
        active && controller.IsAvailable && IsControllerFocused && controllerLayer == ControllerLayer.Record;

    private void AdjustSetting(int direction, bool activate = false)
    {
        switch (settingFocus)
        {
            case 0: config.Scale = Math.Clamp(MathF.Round((config.Scale + direction * .05f) * 20) / 20, .8f, 1.5f); break;
            case 1: config.DarkPaper = !config.DarkPaper; break;
            case 2: config.Ornament = !config.Ornament; break;
            case 3: config.ReplaceCharacter = !config.ReplaceCharacter; break;
            case 4: config.ShowToolbarEntry = !config.ShowToolbarEntry; break;
            case 5: CycleLabels(direction); break;
            case 6: config.SwapConfirmBack = !config.SwapConfirmBack; break;
            case 7: CyclePresentation(direction); break;
            case 8: CyclePlacement(direction); break;
            case 9: if (activate) HostAction(); return;
            case 10: if (activate) OpenOriginal(); return;
            case 11: if (activate) { closeSettings = true; controllerLayer = ControllerLayer.Record; } return;
        }
        save();
    }

    private void DrawControllerPrompts(ImDrawListPtr d, Vector2 p, Vector2 size, float s)
    {
        if (controller.IsAvailable || controllerUsed)
        {
            var color = IsControllerFocused ? PaleGold : Muted;
            var labels = CharacterControllerLabels.For(config.ControllerLabels, config.SwapConfirmBack);
            var confirm = page switch
            {
                CharacterPage.Equipment => $"{labels.Confirm}  Change     ",
                CharacterPage.GearSets => $"{labels.Confirm}  Equip     ",
                _ => "",
            };
            Text(d, p + new Vector2(54 * s, size.Y - 45 * s),
                controller.Phase == "WaitingForNeutral" ? "Release controller buttons to focus this record."
                    : $"D-pad / LS  Select     ← →  {(page == CharacterPage.Equipment ? "Group" : "Page")}     {labels.Tabs}  Sections     RS  Scroll", 12 * s, color, small);
            Text(d, p + new Vector2(54 * s, size.Y - 27 * s),
                $"{confirm}{labels.Back}  Back     {labels.Secondary} / {labels.Armoury}  Armoury Chest     {labels.Details}  Original window     {labels.Appearance}  Appearance", 12 * s, color, small);
        }
        else
        {
            Text(d, p + new Vector2(54 * s, size.Y - 45 * s), "Controller navigation is unavailable. Appearance has connection details.", 12 * s, Muted, small);
            Text(d, p + new Vector2(54 * s, size.Y - 27 * s), "Esc  Close    •    Drag the binding to move", 12 * s, Muted, small);
        }
    }

    // ---- Drawing helpers --------------------------------------------------------------------

    private uint Ink() => config.DarkPaper ? C(234, 226, 204) : C(54, 49, 39);
    private uint Soft() => config.DarkPaper ? C(166, 184, 179) : C(110, 96, 70);
    private uint Edge() => config.DarkPaper ? C(170, 153, 103, 130) : C(143, 112, 57, 110);
    // Active rows use the teal button fill in both palettes: keep their text light.
    private uint RowInk(bool active) => active ? Ivory : Ink();
    private uint RowSoft(bool active) => active ? C(184, 204, 198) : Soft();

    private float Heading(ImDrawListPtr d, Vector2 p, string text, float width, float s)
    {
        Text(d, p, text, 12 * s, Soft(), small);
        d.AddLine(p + new Vector2(0, 19 * s), p + new Vector2(width, 19 * s), Edge());
        return 27 * s;
    }

    private float Line(ImDrawListPtr d, Vector2 p, float w, float s, string label, string value, bool strong)
    {
        var valueWidth = MathF.Min(MeasureText(value, 14 * s, small, 0).X, w * .6f);
        var labelHeight = MeasureText(label, 14 * s, small, w - valueWidth - 12 * s).Y;
        var valueHeight = MeasureText(value, 14 * s, small, w * .6f).Y;
        Text(d, p, label, 14 * s, strong ? Ink() : Soft(), small, w - valueWidth - 12 * s);
        Text(d, p + new Vector2(w - valueWidth, 0), value, 14 * s, Ink(), small, w * .6f);
        return Math.Max(labelHeight, valueHeight) + 6 * s;
    }

    private float Meter(ImDrawListPtr d, Vector2 p, float w, float s, string label, float percent, uint color)
    {
        var value = $"{percent:0.##}%";
        Text(d, p, label, 14 * s, Soft(), small);
        Text(d, p + new Vector2(w - MeasureText(value, 14 * s, small, 0).X, 0), value, 14 * s, Ink(), small);
        var bar = p + new Vector2(0, 20 * s);
        d.AddRectFilled(bar, bar + new Vector2(w, 5 * s), Edge(), 3 * s);
        d.AddRectFilled(bar, bar + new Vector2(w * CharacterMath.Progress((long)(percent * 100), 10000), 5 * s), color, 3 * s);
        return 33 * s;
    }

    private float Centered(ImDrawListPtr d, Vector2 start, float w, float y, string text, float size, uint color, IFontHandle font)
    {
        var measured = MeasureText(text, size, font, w);
        // A wrapped line keeps its own left edge; single lines are centered.
        var x = measured.X < w ? (w - measured.X) / 2 : 0;
        Text(d, start + new Vector2(x, y), text, size, color, font, w - x);
        return measured.Y;
    }

    private static float Wrapped(ImDrawListPtr d, Vector2 p, string text, float size, uint color, IFontHandle font, float wrap)
    {
        Text(d, p, text, size, color, font, wrap);
        return MeasureText(text, size, font, wrap).Y;
    }

    private bool JobIcon(ImDrawListPtr d, uint jobId, uint soulIcon, Vector2 p, float size, bool muted)
    {
        var tint = muted ? C(255, 255, 255, 110) : uint.MaxValue;
        return Icon(d, CharacterMath.JobIconBase + jobId, p, new(size), false, tint)
            || Icon(d, soulIcon, p + new Vector2(size * .1f), new(size * .8f), false, tint);
    }

    /// <summary>Never throws: unknown ids (base classes, limited jobs) fall back to the caller's drawing.</summary>
    private bool Icon(ImDrawListPtr d, uint icon, Vector2 p, Vector2 size, bool hq = false, uint tint = uint.MaxValue)
    {
        if (icon == 0) return false;
        if (hq && TryIcon(d, icon, true, p, size, tint)) return true;
        return TryIcon(d, icon, false, p, size, tint);
    }

    private bool TryIcon(ImDrawListPtr d, uint icon, bool hq, Vector2 p, Vector2 size, uint tint)
    {
        if (missingIcons.Contains((icon, hq))) return false;
        if (!textures.TryGetFromGameIcon(new GameIconLookup(icon, hq), out var shared))
        {
            missingIcons.Add((icon, hq));
            return false;
        }
        if (!shared.TryGetWrap(out var wrap, out _) || wrap is null) return false;
        d.AddImage(wrap.Handle, p, p + size, Vector2.Zero, Vector2.One, tint);
        return true;
    }

    private static void FitPopup(Vector2 preferred, float scale)
    {
        var rectangle = CharacterPopupLayout.Fit(ImGui.GetWindowPos(), ImGui.GetWindowSize(), preferred, scale);
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
            Text(d, p + new Vector2((size.X - width) / 2, (size.Y - fs) / 2 - s), text, fs,
                active ? Ivory : onPaper ? (config.DarkPaper ? Ivory : C(72, 61, 42)) : Ivory, small);
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
