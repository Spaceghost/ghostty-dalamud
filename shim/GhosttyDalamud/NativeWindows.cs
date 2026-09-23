// Terminals in game windows (docs/NATIVE_UI.md): one KamiToolKit addon per
// terminal, whose image node shows a texture the core draws the terminal into
// (Dalamud's IDrawListTextureWrap, handed to the game as a kernel texture that
// shares its D3D11 resource). The core decides everything; this forwards and
// reports. Not yet observed in game.
//
// KamiToolKit is touched only from NativeKami below, and NativeKami only from
// methods marked NoInlining inside a try: a missing or failing KamiToolKit.dll
// is a caught load error (the core then opens ImGui windows), never an
// exception thrown into the game.
using System;
using System.Collections.Generic;
using System.Numerics;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using Dalamud.Bindings.ImGui;
using Dalamud.Interface.Textures.TextureWraps;
using FFXIVClientStructs.FFXIV.Component.GUI;
using KamiToolKit;
using KamiToolKit.BaseTypes;
using KamiToolKit.Nodes;
using Lumina.Text.ReadOnly;

namespace GhosttyDalamud;

internal static unsafe class NativeWindows
{
    // GuNativeState.Status and .Error (core/nativewin.nelua)
    internal const int StatusNone = 0, StatusOpening = 1, StatusOpen = 2, StatusClosed = 3, StatusFailed = 4;
    internal const int ErrKami = 1, ErrOpen = 2, ErrTexture = 3, ErrThread = 4;

    private const int NotStarted = 0, Starting = 1, Ready = 2, Failed = 3;
    private static volatile int _path;
    internal static volatile bool Stopping;

    // Plugin start: KamiToolKit comes up in the background; until then the core waits.
    public static void Start()
    {
        _path = Starting;
        Stopping = false;
        Task started;
        try { started = StartKami(); }
        catch (Exception e) { StartFailed(e); return; }
        // no await here: these classes are unsafe, and an unsafe context cannot await
        started.ContinueWith(t => {
            if (t.IsCompletedSuccessfully) _path = Stopping ? Failed : Ready;
            else StartFailed(t.Exception);
        }, TaskScheduler.Default);
    }

    private static void StartFailed(Exception? e)
    {
        _path = Failed;
        Plugin.Log.Warning(e, "[Ghostty] game windows unavailable: KamiToolKit did not start (terminals open as ImGui windows)");
    }

    [MethodImpl(MethodImplOptions.NoInlining)]
    private static Task StartKami() => NativeKami.StartAsync();

    // Plugin unload, after the core shut down: every addon and KamiToolKit's hooks go.
    public static void Stop()
    {
        Stopping = true;
        if (_path != Ready) { _path = NotStarted; return; }
        _path = NotStarted;
        try { StopKami(); }
        catch (Exception e) { Plugin.Log.Warning(e, "[Ghostty] game windows: KamiToolKit did not stop cleanly"); }
    }

    [MethodImpl(MethodImplOptions.NoInlining)]
    private static void StopKami() => NativeKami.Stop();

    private static string Str(byte* s) => Marshal.PtrToStringUTF8((nint)s) ?? string.Empty;

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    public static int Open(int id, byte* title, float w, float h, float x, float y)
    {
        if (_path != Ready || Stopping || id <= 0) return 0;
        try { return OpenKami(id, Str(title), w, h, x, y) ? 1 : 0; }
        catch (Exception e) { Plugin.Log.Warning(e, "[Ghostty] game window: open failed"); return 0; }
    }

    [MethodImpl(MethodImplOptions.NoInlining)]
    private static bool OpenKami(int id, string title, float w, float h, float x, float y) => NativeKami.Open(id, title, w, h, x, y);

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    public static int Close(int id)
    {
        if (_path != Ready || Stopping) return 0;
        try { return CloseKami(id) ? 1 : 0; } catch { return 0; }
    }

    [MethodImpl(MethodImplOptions.NoInlining)]
    private static bool CloseKami(int id) => NativeKami.Close(id);

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    public static int State(int id, GuNativeState* st)
    {
        if (st == null) return 0;
        *st = default;
        try {
            st->UiHidden = Plugin.GameGui.GameUiHidden ? 1 : 0;
            if (id == 0) {
                st->Status = _path switch { Ready => StatusOpen, Starting => StatusOpening, Failed => StatusFailed, _ => StatusNone };
                if (_path == Failed) st->Error = ErrKami;
                return 1;
            }
            if (_path != Ready) { st->Status = StatusNone; return 1; }
            StateKami(id, st);
            return 1;
        } catch { return 0; }
    }

    [MethodImpl(MethodImplOptions.NoInlining)]
    private static void StateKami(int id, GuNativeState* st) => NativeKami.State(id, st);

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    public static int Draw(int id, void* dl, int texW, int texH, int capW, int capH, float nodeX, float nodeY, float nodeW, float nodeH)
    {
        if (_path != Ready || Stopping || dl == null) return 0;
        try { return DrawKami(id, dl, texW, texH, capW, capH, nodeX, nodeY, nodeW, nodeH) ? 1 : 0; }
        catch (Exception e) { NativeKami.DrawFailed(id, e); return 0; }
    }

    [MethodImpl(MethodImplOptions.NoInlining)]
    private static bool DrawKami(int id, void* dl, int texW, int texH, int capW, int capH, float nodeX, float nodeY, float nodeW, float nodeH) =>
        NativeKami.Draw(id, dl, texW, texH, capW, capH, nodeX, nodeY, nodeW, nodeH);

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    public static int Resize(int id, float w, float h)
    {
        if (_path != Ready || Stopping) return 0;
        try { return ResizeKami(id, w, h) ? 1 : 0; } catch { return 0; }
    }

    [MethodImpl(MethodImplOptions.NoInlining)]
    private static bool ResizeKami(int id, float w, float h) => NativeKami.Resize(id, w, h);

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    public static int Title(int id, byte* title)
    {
        if (_path != Ready || Stopping) return 0;
        try { return TitleKami(id, Str(title)) ? 1 : 0; } catch { return 0; }
    }

    [MethodImpl(MethodImplOptions.NoInlining)]
    private static bool TitleKami(int id, string title) => NativeKami.SetTitle(id, title);
}

// Everything that names a KamiToolKit type. Structural changes (open, close,
// size, title) run on the next framework tick, outside the frame's drawing;
// drawing into the texture runs in UiBuilder.Draw, where Dalamud requires it.
internal static unsafe class NativeKami
{
    private static readonly Dictionary<int, TermAddon> Windows = new();

    public static Task StartAsync() => KamiToolKitLibrary.InitializeAsync(Plugin.Pi, "Ghostty");

    public static void Stop()
    {
        foreach (var a in Windows.Values) {
            try { a.Dispose(); } catch { /* keep going: every addon must go */ }
        }
        Windows.Clear();
        if (Plugin.GameFramework.IsInFrameworkUpdateThread) KamiToolKitLibrary.Dispose();
        else KamiToolKitLibrary.DisposeAsync().Wait(TimeSpan.FromSeconds(5));
    }

    private static void Later(TermAddon a, Action<TermAddon> act)
    {
        Plugin.GameFramework.RunOnTick(() => {
            if (NativeWindows.Stopping) return;
            try { act(a); }
            catch (Exception e) {
                a.Error = NativeWindows.ErrOpen;
                a.Broken = true;
                Plugin.Log.Warning(e, "[Ghostty] game window {Id}", a.TermId);
            }
        });
    }

    public static bool Open(int id, string title, float w, float h, float x, float y)
    {
        if (!Windows.TryGetValue(id, out var a)) {
            a = new TermAddon {
                InternalName = "GhosttyTerm" + id,
                // "Ghostty" in the title font; the terminal's own title (fitted by the core) as the
                // subtitle, whose font has the characters shells put there (~, @, :)
                Title = new ReadOnlySeString("Ghostty".AsSpan()),
                Subtitle = new ReadOnlySeString(title.AsSpan()),
                Size = new Vector2(w, h),
                RememberClosePosition = false, // the core keeps the place (lua/native.lua)
                OpenWindowSoundEffectId = 23,
            };
            a.TermId = id;
            Windows[id] = a;
        }
        a.Broken = false;
        a.Error = 0;
        a.ClosingByUs = false;
        a.Size = new Vector2(Math.Max(w, 240), Math.Max(h, 140));
        a.Subtitle = new ReadOnlySeString(title.AsSpan());
        a.PendingPos = x >= 0 && y >= 0 ? new Vector2(x, y) : null;
        a.Pending = true;
        Later(a, t => { t.Pending = false; t.Open(); });
        return true;
    }

    public static bool Close(int id)
    {
        if (!Windows.TryGetValue(id, out var a)) return false;
        a.ClosingByUs = true;
        a.Pending = false;
        // closed and let go: the core forgets the window; opening the id again makes a new one
        Windows.Remove(id);
        Later(a, t => t.Dispose());
        return true;
    }

    public static void State(int id, GuNativeState* st)
    {
        if (!Windows.TryGetValue(id, out var a)) { st->Status = NativeWindows.StatusNone; return; }
        st->Closes = a.Closes;
        st->Error = a.Error;
        if (a.Broken) { st->Status = NativeWindows.StatusFailed; return; }
        AtkUnitBase* unit = a;
        if (unit == null || !a.SetUp) {
            st->Status = a.Pending || (unit != null && !a.SetUp) ? NativeWindows.StatusOpening : NativeWindows.StatusClosed;
            return;
        }
        st->Status = NativeWindows.StatusOpen;
        if (!unit->IsVisible) st->UiHidden = 1;
        float scale = unit->RootNode != null && unit->RootNode->ScaleX > 0 ? unit->RootNode->ScaleX : unit->Scale;
        st->X = unit->X;
        st->Y = unit->Y;
        st->W = a.Size.X;
        st->H = a.Size.Y;
        st->Scale = scale;
        var cs = a.ContentStartPosition;
        var cz = a.ContentSize;
        st->Cx = cs.X; st->Cy = cs.Y; st->Cw = cz.X; st->Ch = cz.Y;
        // 1 ours, -1 another addon is under the pointer (in front of ours there), 0 none: the
        // core then uses the window's rectangle (the game hit-tests nothing while ImGui has the mouse)
        var stage = AtkStage.Instance();
        if (stage != null && stage->AtkCollisionManager != null) {
            var over = stage->AtkCollisionManager->IntersectingAddon;
            st->Hovered = over == unit ? 1 : over == null ? 0 : -1;
        }
        if (stage != null && stage->RaptureAtkUnitManager != null && stage->RaptureAtkUnitManager->FocusedAddon == unit) st->Focused = 1;
    }

    public static bool Draw(int id, void* dl, int texW, int texH, int capW, int capH, float nodeX, float nodeY, float nodeW, float nodeH)
    {
        if (!Windows.TryGetValue(id, out var a) || !a.SetUp || a.Image is not { } image) return false;
        if (texW < 1 || texH < 1 || capW < texW || capH < texH || capW > 8192 || capH > 8192) return false;
        if (a.Texture is null || a.TexW != capW || a.TexH != capH) {
            var tex = Plugin.Textures.CreateDrawListTexture("ghostty game window " + id);
            tex.Size = new Vector2(capW, capH);
            tex.ClearColor = Vector4.Zero;
            image.LoadTexture(tex); // the node owns it now, and disposed the one before
            a.Texture = tex;
            a.TexW = capW;
            a.TexH = capH;
        }
        a.Texture.Draw(new ImDrawListPtr((ImDrawList*)dl), Vector2.Zero, Vector2.One);
        image.Position = new Vector2(nodeX, nodeY);
        image.Size = new Vector2(nodeW, nodeH);
        image.TextureCoordinates = Vector2.Zero;
        image.TextureSize = new Vector2(texW, texH);
        return true;
    }

    public static void DrawFailed(int id, Exception e)
    {
        if (!Windows.TryGetValue(id, out var a)) return;
        a.Error = e is InvalidOperationException && e.Message.Contains("thread", StringComparison.OrdinalIgnoreCase)
            ? NativeWindows.ErrThread : NativeWindows.ErrTexture;
        if (!a.DrawErrorLogged) {
            a.DrawErrorLogged = true;
            Plugin.Log.Warning(e, "[Ghostty] game window {Id}: drawing the terminal texture failed", id);
        }
    }

    public static bool Resize(int id, float w, float h)
    {
        if (!Windows.TryGetValue(id, out var a)) return false;
        var size = new Vector2(Math.Max(w, 240), Math.Max(h, 140));
        Later(a, t => {
            if (!t.SetUp) { t.Size = size; return; }
            t.SetWindowSize(size);
            t.Layout();
        });
        return true;
    }

    public static bool SetTitle(int id, string title)
    {
        if (!Windows.TryGetValue(id, out var a)) return false;
        Later(a, t => {
            t.Subtitle = new ReadOnlySeString(title.AsSpan());
            if (t.SetUp) t.ShowTitle(title);
        });
        return true;
    }
}

// One terminal's game window: the game's window frame with one image node in
// its content area.
internal sealed unsafe class TermAddon : NativeAddon
{
    public int TermId;
    public ImGuiImageNode? Image;
    public IDrawListTextureWrap? Texture; // owned by Image once loaded
    public int TexW, TexH;
    public bool SetUp, Pending, ClosingByUs, Broken, DrawErrorLogged;
    public int Closes, Error;
    public Vector2? PendingPos;

    protected override void OnSetup(AtkUnitBase* addon, Span<AtkValue> atkValueSpan)
    {
        Image = new ImGuiImageNode {
            Position = ContentStartPosition,
            Size = ContentSize,
            WrapMode = KamiToolKit.Enums.WrapMode.Stretch, // the part (texels) stretched over the node, one texel per screen pixel
            IsVisible = true,
        };
        AddNode(Image);
        Texture = null;
        TexW = TexH = 0;
        if (PendingPos is { } p) SetWindowPosition(p);
        SetUp = true;
    }

    // after a resize: the image node follows the content area (the core sets
    // its exact place and size on the next draw)
    public void Layout()
    {
        if (Image is null) return;
        Image.Position = ContentStartPosition;
        Image.Size = ContentSize;
    }

    public void ShowTitle(string title)
    {
        if (WindowNode is { } w) w.SetTitle("Ghostty", title);
    }

    protected override void OnFinalize(AtkUnitBase* addon)
    {
        SetUp = false;
        Image = null; // KamiToolKit disposes the node, and the texture with it
        Texture = null;
        TexW = TexH = 0;
        if (!ClosingByUs) Closes++;
        ClosingByUs = false;
    }
}
