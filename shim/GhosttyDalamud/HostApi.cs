// GuHostApi callbacks: Dalamud and game facilities handed to the core. Each
// one only reads, writes or calls; anything that can throw returns 0 instead.
using System;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Threading;
using System.Threading.Tasks;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using Dalamud.Game.ClientState.GamePad;
using Dalamud.Game.ClientState.Keys;
using Dalamud.Game.Command;
using Dalamud.Game.Gui.Dtr;
using Dalamud.Interface;
using Dalamud.Interface.ManagedFontAtlas;
using RenderLightFlags = FFXIVClientStructs.FFXIV.Client.Graphics.Render.LightFlags;
using SceneLight = FFXIVClientStructs.FFXIV.Client.Graphics.Scene.Light;
using BgObject = FFXIVClientStructs.FFXIV.Client.Graphics.Scene.BgObject;

namespace GhosttyDalamud;

internal static unsafe class HostApi
{
    public static GuHostApi* Api { get; private set; }

    private static IDisposable? _fontScope;
    private static IFontHandle? _monoFont;
    private static IFontHandle? _worldFont;
    private static IDtrBarEntry? _dtr;

    public static void Create()
    {
        _monoFont = TerminalFont(UiBuilder.DefaultFontSizePx);
        // a large mono font for world panels: glyphs get minified instead of magnified
        _worldFont = TerminalFont(40);

        Api = (GuHostApi*)NativeMemory.AllocZeroed((nuint)sizeof(GuHostApi));
        Api->Size           = (nuint)sizeof(GuHostApi);
        Api->Log            = &LogCallback;
        Api->PushMonoFont   = &PushMonoFont;
        Api->PopFont        = &PopFont;
        Api->ConsumeKey     = &ConsumeKey;
        Api->ResolveImGui   = null; // the core resolves cimgui.dll exports itself
        Api->GamepadPressed = &GamepadPressed;
        Api->GamepadDown    = &GamepadDown;
        Api->GetCamera      = &GetCamera;
        Api->GetObject      = &GetObject;
        Api->SetRotation    = &SetRotation;
        Api->AnimGet        = &AnimGet;
        Api->AnimSet        = &AnimSet;
        Api->AnimPlay       = &AnimPlay;
        Api->AnimSpeed      = &AnimSpeed;
        Api->GetEnvironment = &GetEnvironment;
        Api->PushWorldFont  = &PushWorldFont;
        Api->GetCameraState = &GetCameraState;
        Api->SetCameraState = &SetCameraState;
        Api->LightCreate    = &LightCreate;
        Api->LightUpdate    = &LightUpdate;
        Api->LightDestroy   = &LightDestroy;
        // look-at by position needs a sig-scanned game function called from a
        // hook (see Brio's ActorLookAtService); ClientStructs exposes neither
        Api->SetLookAt      = null;
        Api->CommandAdd     = &CommandAdd;
        Api->CommandRemove  = &CommandRemove;
        Api->DtrSet         = &DtrSet;
        Api->DtrRemove      = &DtrRemove;
        Api->SetUiHide      = &SetUiHide;
        Api->PluginLoaded   = &PluginLoaded;
        Api->IpcRegister    = &IpcRegister;
        Api->IpcUnregister  = &IpcUnregister;
        Api->Raycast        = &Raycast;
        Api->GetSceneDepth  = &GetSceneDepth;
        Api->OpenUrl        = &OpenUrl;
        // BgObject.Create is found once, here; without it the core leaves shadow boards off
        Api->BgCreate       = null;
        if (ResolveBgCreate()) Api->BgCreate = &BgCreate;
        Api->BgReady        = &BgReady;
        Api->BgSetTransform = &BgSetTransform;
        Api->BgSetTransparency = &BgSetTransparency;
        Api->BgDestroy      = &BgDestroy;
        Api->CommandAddTagged = &CommandAddTagged;
        Api->ChatPrint      = &ChatPrint;
        Api->AddonRect      = &AddonRect;
        Api->AddonShow      = &AddonShow;
        Api->ChatSend       = &ChatSend;
        Api->ConfigUInt     = &ConfigUInt;
        Api->TextureFile    = &TextureFile;
        Api->SceneFlags     = &SceneFlags;
        Api->HttpUpload     = &HttpUpload;
        Api->GameString     = &GameString;
        Api->HudRects       = &HudRects;
        Api->HttpPost       = &HttpPost;
        Api->Indoor         = &Indoor;
        Api->GameLookup     = &GameLookup;
        Api->GameAction     = &GameAction;
        Api->TextureIcon    = &TextureIcon;
        Api->NativeOpen     = &NativeWindows.Open;
        Api->NativeClose    = &NativeWindows.Close;
        Api->NativeState    = &NativeWindows.State;
        Api->NativeDraw     = &NativeWindows.Draw;
        Api->NativeResize   = &NativeWindows.Resize;
        Api->NativeTitle    = &NativeWindows.Title;
        Api->PushMonoFontPx = &PushMonoFontPx;
        Api->NearbyCharacters = &NearbyCharacters;
        Api->RaycastMode    = &RaycastMode;
        Api->CastInfo       = &CastInfo;
    }

    public static void Free()
    {
        NativeMemory.Free(Api);
        Api = null;
        foreach (var f in _sizedFonts.Values) f.Dispose();
        _sizedFonts.Clear();
        _sizedOrder.Clear();
        _worldFont?.Dispose();
        _worldFont = null;
        _monoFont?.Dispose();
        _monoFont = null;
    }

    private static string Str(byte* s) => Marshal.PtrToStringUTF8((nint)s) ?? string.Empty;

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static void LogCallback(int level, byte* msg)
    {
        string s = "[Ghostty] " + Str(msg);
        switch (level) {
            case 3:  Plugin.Log.Error(s); break;
            case 2:  Plugin.Log.Warning(s); break;
            default: Plugin.Log.Information(s); break;
        }
    }

    // Chat commands, the info bar entry, UI hiding and IPC -----------------------------------

    private static void OnCommand(string command, string args) => Native.Post(GuEvent.Chat, 0, 0, 0, 0, args);

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static int CommandAdd(byte* name, byte* help)
    {
        try { return Plugin.Commands.AddHandler(Str(name), new CommandInfo(OnCommand) { HelpMessage = Str(help) }) ? 1 : 0; }
        catch { return 0; }
    }

    // a command of its own (/window, /ask): the core knows it by `tag`
    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static int CommandAddTagged(byte* name, byte* help, int tag)
    {
        try {
            return Plugin.Commands.AddHandler(Str(name), new CommandInfo((_, args) => Native.Post(GuEvent.Chat, tag, 0, 0, 0, args)) { HelpMessage = Str(help) }) ? 1 : 0;
        }
        catch { return 0; }
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static int CommandRemove(byte* name)
    {
        try { return Plugin.Commands.RemoveHandler(Str(name)) ? 1 : 0; } catch { return 0; }
    }

    private static void OnDtrClick(DtrInteractionEvent e)
        => Native.Post(GuEvent.DtrClick, (int)e.ClickType, (int)e.ModifierKeys, e.Position.X, e.Position.Y, string.Empty);

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static int DtrSet(byte* title, byte* text, byte* tooltip, int shown)
    {
        try {
            _dtr ??= Plugin.Dtr.Get(Str(title));
            _dtr.Text    = Str(text);
            _dtr.Tooltip = Str(tooltip);
            _dtr.Shown   = shown != 0;
            _dtr.OnClick = OnDtrClick;
            return 1;
        } catch { return 0; }
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static void DtrRemove()
    {
        try { _dtr?.Remove(); } catch { /* already gone */ }
        _dtr = null;
    }

    // bits: 1 DisableAutomaticUiHide, 2 DisableUserUiHide, 4 DisableCutsceneUiHide, 8 DisableGposeUiHide
    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static void SetUiHide(int mask)
    {
        var ui = Plugin.Pi.UiBuilder;
        ui.DisableAutomaticUiHide = (mask & 1) != 0;
        ui.DisableUserUiHide      = (mask & 2) != 0;
        ui.DisableCutsceneUiHide  = (mask & 4) != 0;
        ui.DisableGposeUiHide     = (mask & 8) != 0;
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static int PluginLoaded(byte* name)
    {
        try {
            string n = Str(name);
            return Plugin.Pi.InstalledPlugins.Any(p => p.InternalName == n && p.IsLoaded) ? 1 : 0;
        } catch { return 0; }
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static int IpcRegister()
    {
        try { GhosttyIpc.Register(); return 1; } catch { return 0; }
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static void IpcUnregister()
    {
        try { GhosttyIpc.Unregister(); } catch { /* the core is shutting down either way */ }
    }

    // a line in the game chat; what to say and when is the core's
    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static int ChatPrint(byte* text)
    {
        if (text == null) return 0;
        try { Plugin.Chat.Print(Str(text)); return 1; } catch { return 0; }
    }

    // an image file (the Windows picker's app icons) as an ImTextureID, 0 until
    // Dalamud has loaded it; asked again every frame it is drawn (a shared
    // texture Dalamud keeps while it is used). Which file, and when, is the core's.
    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static nint TextureFile(byte* path, uint* w, uint* h)
    {
        if (path == null) return 0;
        try {
            if (!Plugin.Textures.GetFromFile(Str(path)).TryGetWrap(out var wrap, out _) || wrap == null) return 0;
            if (w != null) *w = (uint)wrap.Width;
            if (h != null) *h = (uint)wrap.Height;
            return (nint)wrap.Handle.Handle;
        } catch { return 0; }
    }

    // the core only passes https links; opening one is Dalamud's job
    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static int OpenUrl(byte* url)
    {
        if (url == null) return 0;
        try { Dalamud.Utility.Util.OpenLink(Str(url)); return 1; } catch { return 0; }
    }

    // The /ask panel's game links (GameLinks.cs, lua/asklinks.lua) ----------------------------------

    // Names the game knows, as text into buf (NUL terminated, cut to cap); its length.
    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static nuint GameLookup(byte* request, byte* buf, nuint cap)
    {
        if (buf == null || cap == 0) return 0;
        try {
            byte[] bytes = System.Text.Encoding.UTF8.GetBytes(GameLinks.Lookup(Str(request)));
            int n = (int)Math.Min((nuint)bytes.Length, cap - 1);
            // never half a line: cut back to the last line end that fits
            if (n < bytes.Length) { while (n > 0 && bytes[n - 1] != (byte)'\n') n--; }
            for (int i = 0; i < n; i++) buf[i] = bytes[i];
            buf[n] = 0;
            return (nuint)n;
        } catch { buf[0] = 0; return 0; }
    }

    // One of the few things a click on a link may do: 1 done or queued, 0 not
    // possible, 2 refused in combat, 3 not logged in.
    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static int GameAction(byte* verb, byte* arg)
    {
        try { return GameLinks.Action(Str(verb), Str(arg)); } catch { return 0; }
    }

    // A game icon (by icon id) as an ImTextureID, 0 until Dalamud has loaded it.
    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static nint TextureIcon(uint icon, uint* w, uint* h) => GameLinks.Icon(icon, w, h);

    // Flat windows pulled into the world (docs/ADOPT.md) ------------------------------------------

    // A game addon's rectangle on the screen: 1 shown, 2 loaded but hidden, 0 not loaded.
    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static int AddonRect(byte* name, float* x, float* y, float* w, float* h)
    {
        try {
            var a = Plugin.GameGui.GetAddonByName(Str(name), 1);
            if (a.IsNull) return 0;
            *x = a.X; *y = a.Y; *w = a.ScaledWidth; *h = a.ScaledHeight;
            return a.IsVisible ? 1 : 2;
        } catch { return 0; }
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static int AddonShow(byte* name, int shown)
    {
        try {
            var a = Plugin.GameGui.GetAddonByName(Str(name), 1);
            if (a.IsNull) return 0;
            ((FFXIVClientStructs.FFXIV.Component.GUI.AtkUnitBase*)a.Address)->IsVisible = shown != 0;
            return 1;
        } catch { return 0; }
    }

    // What the chat input itself allows (xiv-mcp's ChatInput): anything the game
    // would strip makes the line differ after sanitising, and it is refused.
    private const FFXIVClientStructs.FFXIV.Client.System.String.AllowedEntities ChatAllowed =
        (FFXIVClientStructs.FFXIV.Client.System.String.AllowedEntities)0x27F;

    // A line through the game's chat box, as if typed and sent with Enter; on
    // the framework thread. 1 = queued (a refusal is logged there).
    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static int ChatSend(byte* text)
    {
        try {
            string line = Str(text);
            if (line.Length == 0 || System.Text.Encoding.UTF8.GetByteCount(line) > 500) return 0;
            Plugin.GameFramework.RunOnFrameworkThread(() => SubmitChat(line));
            return 1;
        } catch { return 0; }
    }

    // The same, for a slash command the /ask panel's confirm let through (GameLinks).
    public static bool QueueChat(string line)
    {
        if (line.Length == 0 || System.Text.Encoding.UTF8.GetByteCount(line) > 500) return false;
        Plugin.GameFramework.RunOnFrameworkThread(() => SubmitChat(line));
        return true;
    }

    private static void SubmitChat(string line)
    {
        var ui = FFXIVClientStructs.FFXIV.Client.UI.UIModule.Instance();
        if (ui == null) { Plugin.Log.Warning("[Ghostty] chat: the game UI is not ready"); return; }
        var str = FFXIVClientStructs.FFXIV.Client.System.String.Utf8String.FromString(line);
        if (str == null) return;
        try {
            str->SanitizeString(ChatAllowed, null);
            if (!string.Equals(str->ToString(), line, StringComparison.Ordinal)) {
                Plugin.Log.Warning("[Ghostty] chat: the line has characters the game's chat box does not accept; not sent");
                return;
            }
            ui->ProcessChatBoxEntry(str, 0, false);
        } finally {
            str->Dtor(true);
        }
    }

    // A UiConfig option as a number (the chat log colours: ColorSay, ...).
    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static int ConfigUInt(byte* name, uint* value)
    {
        try {
            if (!Plugin.GameConfig.UiConfig.TryGetUInt(Str(name), out uint v)) return 0;
            *value = v;
            return 1;
        } catch { return 0; }
    }

    // A game or Dalamud string the core asks for by name, as UTF-8 into buf (NUL
    // terminated, cut to cap). Returns its length; 0 when there is none.
    //   screenshot_dir  the game's own screenshot folder setting (empty: the default)
    //   user_path       the game's user folder (FFXIV.cfg, and screenshots\ by default)
    //   player          "Name@World" of the logged-in character
    //   cjk_font        Dalamud's Noto Sans CJK file, for the core's fallback
    //                   glyph chain (core/glyphfb.nelua); empty when it is not there
    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static nuint GameString(byte* name, byte* buf, nuint cap)
    {
        if (buf == null || cap == 0) return 0;
        try {
            string v = Str(name) switch {
                "screenshot_dir" => Plugin.GameConfig.System.TryGetString("ScreenShotDir", out string d) ? d : string.Empty,
                "user_path" => FFXIVClientStructs.FFXIV.Client.System.Framework.Framework.Instance()->UserPathString,
                "player" => Plugin.Objects.LocalPlayer is { } p ? p.Name.TextValue + "@" + p.HomeWorld.Value.Name.ToString() : string.Empty,
                "cjk_font" => CjkFontPath(),
                _ => string.Empty,
            };
            byte[] bytes = System.Text.Encoding.UTF8.GetBytes(v);
            int n = (int)Math.Min((nuint)bytes.Length, cap - 1);
            for (int i = 0; i < n; i++) buf[i] = bytes[i];
            buf[n] = 0;
            return (nuint)n;
        } catch { buf[0] = 0; return 0; }
    }

    // The game's HUD (core/hudmask.nelua): the rectangle and name of every
    // loaded addon that is shown, in AtkStage's order, at most `cap`. The core
    // decides which ones count. Returns how many were written.
    // Shown means drawn, not only flagged visible: an addon the HUD layout or
    // another plugin hides by hiding or fading out its root node (or the whole
    // unit), or one moved entirely off the screen, still has IsVisible set,
    // and cutting a panel for it left see-through squares where nothing is.
    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static int HudRects(GuHudRect* rects, int cap)
    {
        if (rects == null || cap <= 0) return 0;
        try {
            var stage = FFXIVClientStructs.FFXIV.Component.GUI.AtkStage.Instance();
            if (stage == null || stage->RaptureAtkUnitManager == null) return 0;
            ref var list = ref stage->RaptureAtkUnitManager->AllLoadedUnitsList;
            int n = 0;
            for (int i = 0; i < list.Count && n < cap; i++) {
                var unit = list.Entries[i].Value;
                if (unit == null) continue;
                var a = new Dalamud.Game.NativeWrapper.AtkUnitBasePtr((nint)unit);
                if (!a.IsVisible || !Drawn(unit)) continue;
                GuHudRect* r = &rects[n++];
                r->X = a.X; r->Y = a.Y; r->W = a.ScaledWidth; r->H = a.ScaledHeight;
                string name = a.Name ?? string.Empty; // addon names are ASCII
                int len = Math.Min(name.Length, 31);
                for (int k = 0; k < len; k++) r->Name[k] = (byte)name[k];
                r->Name[len] = 0;
            }
            return n;
        } catch { return 0; }
    }

    // Whether an addon puts anything on the screen: its root node shown and
    // not faded out (the unit's own alpha too), and some of it on the screen.
    private static bool Drawn(FFXIVClientStructs.FFXIV.Component.GUI.AtkUnitBase* unit)
    {
        var root = unit->RootNode;
        if (root == null || !root->IsVisible() || root->Color.A == 0) return false;
        if (unit->Alpha == 0 || root->ScaleX <= 0 || root->ScaleY <= 0) return false;
        var dev = FFXIVClientStructs.FFXIV.Client.Graphics.Kernel.Device.Instance();
        if (dev != null && dev->Width > 0 && dev->Height > 0) {
            float x = unit->X, y = unit->Y;
            float w = root->Width * root->ScaleX, h = root->Height * root->ScaleY;
            if (x >= dev->Width || y >= dev->Height || x + w <= 0 || y + h <= 0) return false;
        }
        return true;
    }

    // The Noto Sans CJK file in Dalamud's asset folder, the same one the
    // terminal font merges kana and CJK punctuation from. The core reads it
    // with stb_truetype for the ideographs the merged ranges leave out (they
    // would cost tens of megabytes in ImGui's atlas: docs/GLYPHS.md). First
    // match wins; empty when Dalamud has not downloaded them.
    private static readonly string[] CjkAssets = [
        "NotoSansCJK-Regular.ttc", "NotoSansCJKjp-Medium.otf", "NotoSansKR-Regular.otf"];

    private static string CjkFontPath()
    {
        string dir = Path.Combine(Plugin.Pi.DalamudAssetDirectory.FullName, "UIRes");
        foreach (string f in CjkAssets) {
            string p = Path.Combine(dir, f);
            if (File.Exists(p)) return p;
        }
        return string.Empty;
    }

    // Uploads (the screenshot gallery, lua/gallery.lua): see GalleryUpload below.
    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static int HttpUpload(int id, byte* url, byte* path, byte* contentType)
    {
        if (url == null || path == null || contentType == null) return 0;
        try { GalleryUpload.Start(id, Str(url), Str(path), Str(contentType)); return 1; } catch { return 0; }
    }

    // The gallery's sign-in and its signed upload: extra headers ("Name: value" lines), and
    // the file at `path` or else `bodyLen` bytes at `body`. The headers and the body carry
    // the player's sign-in: they are copied here and never logged.
    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static int HttpPost(int id, byte* url, byte* headers, byte* contentType, byte* path, byte* body, nuint bodyLen)
    {
        if (url == null || contentType == null || (path == null && body == null)) return 0;
        try {
            byte[]? bytes = null;
            if (path == null) bytes = new ReadOnlySpan<byte>(body, checked((int)bodyLen)).ToArray();
            GalleryUpload.Start(id, Str(url), path == null ? null : Str(path), Str(contentType),
                headers == null ? null : Str(headers), bytes);
            return 1;
        } catch { return 0; }
    }

    // Before the core goes away: no upload may call into it afterwards.
    public static void StopHttp() => GalleryUpload.Stop();

    // Fonts and keys -----------------------------------------------------------------------------

    // Glyph ranges (inclusive pairs, zero-terminated). Inconsolata is asked for
    // everything a terminal commonly shows and gives what it has; each merged
    // font then fills only glyphs still missing.
    private static readonly ushort[] TextRanges = [
        0x0020, 0x024F, 0x0370, 0x03FF, 0x0400, 0x04FF, 0x2000, 0x2BFF, 0xFFFD, 0xFFFD, 0];
    private static readonly ushort[] NerdRanges = [
        0x23FB, 0x23FE, 0x2665, 0x2665, 0x26A1, 0x26A1, 0x2B58, 0x2B58, 0xE000, 0xF8FF, 0];
    private static readonly ushort[] SymbolRanges = [0x2000, 0x2BFF, 0];
    // CJK punctuation, kana and fullwidth forms only: about 800 glyphs. The
    // 21,000 unified ideographs would need a 4096-wide ImGui atlas per font
    // size, so they are rasterized on demand into the core's own 1024x1024
    // atlas instead, from the same file (core/glyphfb.nelua, docs/GLYPHS.md).
    private static readonly ushort[] CjkRanges = [
        0x2000, 0x2BFF, 0x3000, 0x30FF, 0xFF00, 0xFFEF, 0];

    // Inconsolata, then Nerd Font icons and Noto symbols from fonts/, then the
    // punctuation and kana of Dalamud's Noto Sans CJK.
    private static IFontHandle TerminalFont(float sizePx) =>
        Plugin.Pi.UiBuilder.FontAtlas.NewDelegateFontHandle(e => e.OnPreBuild(tk =>
        {
            var font = tk.AddDalamudAssetFont(Dalamud.DalamudAsset.InconsolataRegular,
                new SafeFontConfig { SizePx = sizePx, GlyphRanges = TextRanges });
            string dir = Path.Combine(Plugin.Pi.AssemblyLocation.DirectoryName!, "fonts");
            foreach (var (file, ranges) in new[] {
                ("SymbolsNerdFontMono-Regular.ttf", NerdRanges), ("NotoSansSymbols2-Regular.ttf", SymbolRanges) })
            {
                string path = Path.Combine(dir, file);
                if (File.Exists(path))
                    tk.AddFontFromFile(path, new SafeFontConfig { SizePx = sizePx, GlyphRanges = ranges, MergeFont = font });
            }
            tk.AddDalamudAssetFont(Dalamud.DalamudAsset.NotoSansCjkRegular,
                new SafeFontConfig { SizePx = sizePx, GlyphRanges = CjkRanges, MergeFont = font });
        }));

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static void PushMonoFont()
    {
        _fontScope = _monoFont is { Available: true } ? _monoFont.Push() : Plugin.Pi.UiBuilder.MonoFontHandle.Push();
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static void PushWorldFont()
    {
        _fontScope = _worldFont is { Available: true } ? _worldFont.Push() : Plugin.Pi.UiBuilder.MonoFontHandle.Push();
    }

    // The terminal font at an exact pixel size, for game windows at any UI scale
    // (core/app/nativeview.nelua): built by the font atlas in the background the
    // first time a size is asked for (0 = not ready, nothing pushed), the four
    // sizes used last kept.
    private const int SizedFontsKept = 4;
    private static readonly System.Collections.Generic.Dictionary<int, IFontHandle> _sizedFonts = new();
    private static readonly System.Collections.Generic.List<int> _sizedOrder = new();

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static int PushMonoFontPx(float px)
    {
        try {
            if (!(px >= 4 && px <= 128)) return 0;
            int key = (int)MathF.Round(px);
            if (!_sizedFonts.TryGetValue(key, out var handle)) {
                while (_sizedOrder.Count >= SizedFontsKept) {
                    int old = _sizedOrder[0];
                    _sizedOrder.RemoveAt(0);
                    if (_sizedFonts.Remove(old, out var gone)) gone.Dispose();
                }
                handle = TerminalFont(key);
                _sizedFonts[key] = handle;
            }
            _sizedOrder.Remove(key);
            _sizedOrder.Add(key);
            if (!handle.Available) return 0;
            _fontScope = handle.Push();
            return 1;
        } catch { return 0; }
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static void PopFont()
    {
        _fontScope?.Dispose();
        _fontScope = null;
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static void ConsumeKey(int vk)
    {
        try { Plugin.Keys[(VirtualKey)vk] = false; } catch { /* key not valid for this game build */ }
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static int GamepadPressed(int mask)
    {
        try { return Plugin.Gamepad.Pressed((GamepadButtons)mask) > 0 ? 1 : 0; } catch { return 0; }
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static int GamepadDown(int mask)
    {
        try { return Plugin.Gamepad.Raw((GamepadButtons)mask) > 0 ? 1 : 0; } catch { return 0; }
    }

    // The game's walk input (same hook as vnavmesh's OverrideMovement) --------------------------
    // The original fills in the player's own input, then the core may steer a
    // walk-up while the player is not steering.
    private delegate void RMIWalkDelegate(void* self, float* sumLeft, float* sumForward, float* sumTurnLeft, byte* haveBackwardOrStrafe, byte* a6, byte bAdditiveUnk);
    private static Dalamud.Hooking.Hook<RMIWalkDelegate>? _walkHook;
    private static delegate* unmanaged<void*, byte> _walkInputEnabled1;
    private static delegate* unmanaged<void*, byte> _walkInputEnabled2;

    public static void HookWalkInput()
    {
        try {
            _walkInputEnabled1 = (delegate* unmanaged<void*, byte>)Plugin.Sigs.ScanText("E8 ?? ?? ?? ?? 84 C0 75 10 38 43 3C");
            _walkInputEnabled2 = (delegate* unmanaged<void*, byte>)Plugin.Sigs.ScanText("E8 ?? ?? ?? ?? 84 C0 75 03 88 47 3F");
            _walkHook = Plugin.Interop.HookFromAddress<RMIWalkDelegate>(Plugin.Sigs.ScanText("E8 ?? ?? ?? ?? 80 7B 3E 00 48 8D 3D"), WalkDetour);
            _walkHook.Enable();
        } catch (Exception e) {
            Plugin.Log.Warning($"[Ghostty] walk-up unavailable: {e.Message}");
        }
    }

    public static void UnhookWalkInput()
    {
        _walkHook?.Dispose();
        _walkHook = null;
    }

    private static void WalkDetour(void* self, float* sumLeft, float* sumForward, float* sumTurnLeft, byte* haveBackwardOrStrafe, byte* a6, byte bAdditiveUnk)
    {
        _walkHook!.Original(self, sumLeft, sumForward, sumTurnLeft, haveBackwardOrStrafe, a6, bAdditiveUnk);
        try {
            var allowed = bAdditiveUnk == 0 && _walkInputEnabled1(self) != 0 && _walkInputEnabled2(self) != 0;
            var legacy = Plugin.GameConfig.UiControl.TryGetUInt("MoveMode", out var mode) && mode == 1;
            Native.WalkInput(sumLeft, sumForward, allowed ? 1 : 0, legacy ? 1 : 0);
        } catch { /* never break the game's movement */ }
    }

    // Camera, objects, animation, environment -----------------------------------------------------

    // Game camera orbit angles and zoom (Distance at MinDistance = first person).
    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static int GetCameraState(float* dirH, float* dirV, float* distance, float* minDistance)
    {
        try {
            var cm = FFXIVClientStructs.FFXIV.Client.Game.Control.CameraManager.Instance();
            if (cm == null || cm->Camera == null) return 0;
            var c = cm->Camera;
            *dirH = c->DirH; *dirV = c->DirV; *distance = c->Distance; *minDistance = c->MinDistance;
            return 1;
        } catch { return 0; }
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static int SetCameraState(float dirH, float dirV, float distance)
    {
        try {
            var cm = FFXIVClientStructs.FFXIV.Client.Game.Control.CameraManager.Instance();
            if (cm == null || cm->Camera == null) return 0;
            var c = cm->Camera;
            c->DirH = dirH; c->DirV = dirV; c->Distance = distance;
            return 1;
        } catch { return 0; }
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static int GetCamera(GuCamera* cam)
    {
        var control = FFXIVClientStructs.FFXIV.Client.Game.Control.Control.Instance();
        var device  = FFXIVClientStructs.FFXIV.Client.Graphics.Kernel.Device.Instance();
        if (control == null || device == null) return 0;
        cam->ViewProjection = control->ViewProjectionMatrix;
        cam->Width          = device->Width;
        cam->Height         = device->Height;
        return 1;
    }

    // the game's scene depth view and the device Dalamud draws ImGui with (borrowed, no AddRef)
    [UnmanagedCallersOnly(CallConvs = [typeof(System.Runtime.CompilerServices.CallConvCdecl)])]
    private static int GetSceneDepth(GuSceneDepth* o)
    {
        try {
            var rtm = FFXIVClientStructs.FFXIV.Client.Graphics.Render.RenderTargetManager.Instance();
            if (rtm == null || rtm->DepthStencil == null) return 0;
            var depth = rtm->DepthStencil;
            o->Srv             = (nint)depth->D3D11ShaderResourceView;
            o->UiDevice        = Plugin.Pi.UiBuilder.DeviceHandle;
            o->ActualWidth     = depth->ActualWidth;
            o->ActualHeight    = depth->ActualHeight;
            o->AllocatedWidth  = depth->AllocatedWidth;
            o->AllocatedHeight = depth->AllocatedHeight;
            return 1;
        } catch { return 0; }
    }

    // which: 0 local player, 1 current target, 2 object by entity id
    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static int GetObject(int which, ulong entityId, GuObject* o)
    {
        try {
            var obj = which switch {
                0 => Plugin.Objects.LocalPlayer,
                1 => Plugin.Targets.Target,
                _ => Plugin.Objects.SearchById(entityId),
            };
            *o = default;
            if (obj == null) return 1;
            o->X = obj.Position.X; o->Y = obj.Position.Y; o->Z = obj.Position.Z;
            o->Rotation  = obj.Rotation;
            o->EntityId  = obj.GameObjectId;
            o->Territory = Plugin.Client.TerritoryType;
            o->Found     = 1;
            o->Height    = ((FFXIVClientStructs.FFXIV.Client.Game.Object.GameObject*)obj.Address)->Height;
            o->HitboxRadius = obj.HitboxRadius;
            o->InCombat  = Plugin.Condition[Dalamud.Game.ClientState.Conditions.ConditionFlag.InCombat] ? 1 : 0;
            o->Mounted   = Plugin.Condition[Dalamud.Game.ClientState.Conditions.ConditionFlag.Mounted] ? 1 : 0;
            return 1;
        } catch { return 0; }
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static int SetRotation(float rotation)
    {
        try {
            if (Plugin.Objects.LocalPlayer is not { } p) return 0;
            ((FFXIVClientStructs.FFXIV.Client.Game.Object.GameObject*)p.Address)->SetRotation(rotation);
            return 1;
        } catch { return 0; }
    }

    // Local player animation state, as posing plugins (Brio) drive it.
    private static FFXIVClientStructs.FFXIV.Client.Game.Character.Character* LocalCharacter()
        => Plugin.Objects.LocalPlayer is { } p ? (FFXIVClientStructs.FFXIV.Client.Game.Character.Character*)p.Address : null;

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static int AnimGet(byte* mode, byte* param, ushort* baseOverride, ushort* baseCurrent)
    {
        try {
            var c = LocalCharacter();
            if (c == null) return 0;
            *mode = (byte)c->Mode; *param = c->ModeParam; *baseOverride = c->Timeline.BaseOverride;
            *baseCurrent = (ushort)c->Timeline.TimelineSequencer.TimelineIds[0];
            return 1;
        } catch { return 0; }
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static int AnimSet(byte mode, byte param, ushort baseOverride, int useSetMode)
    {
        try {
            var c = LocalCharacter();
            if (c == null) return 0;
            // mode 255 = leave the character's mode alone (only the pose changes)
            if (mode != 255) {
                if (useSetMode != 0) c->SetMode((FFXIVClientStructs.FFXIV.Client.Game.Character.CharacterModes)mode, param);
                else { c->Mode = (FFXIVClientStructs.FFXIV.Client.Game.Character.CharacterModes)mode; c->ModeParam = param; }
            }
            c->Timeline.BaseOverride = baseOverride;
            return 1;
        } catch { return 0; }
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static int AnimPlay(ushort timeline)
    {
        try {
            var c = LocalCharacter();
            if (c == null) return 0;
            c->Timeline.TimelineSequencer.PlayTimeline(timeline);
            return 1;
        } catch { return 0; }
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static int AnimSpeed(uint slot, float speed)
    {
        try {
            var c = LocalCharacter();
            if (c == null) return 0;
            c->Timeline.TimelineSequencer.SetSlotSpeed(slot, speed);
            return 1;
        } catch { return 0; }
    }

    // What the game is busy with, for props that must not stay in a scene they
    // do not belong to (the desk scene): 1 cutscene, 2 group pose, 4 between
    // areas, 8 bound by an event (talking to an NPC, a quest event).
    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static int SceneFlags()
    {
        try {
            var c = Plugin.Condition;
            int f = 0;
            if (c[Dalamud.Game.ClientState.Conditions.ConditionFlag.OccupiedInCutSceneEvent]
                || c[Dalamud.Game.ClientState.Conditions.ConditionFlag.WatchingCutscene]
                || c[Dalamud.Game.ClientState.Conditions.ConditionFlag.WatchingCutscene78]) f |= 1;
            if (Plugin.Client.IsGPosing) f |= 2;
            if (c[Dalamud.Game.ClientState.Conditions.ConditionFlag.BetweenAreas]
                || c[Dalamud.Game.ClientState.Conditions.ConditionFlag.BetweenAreas51]) f |= 4;
            if (c[Dalamud.Game.ClientState.Conditions.ConditionFlag.OccupiedInEvent]
                || c[Dalamud.Game.ClientState.Conditions.ConditionFlag.OccupiedInQuestEvent]) f |= 8;
            return f;
        } catch { return 0; }
    }

    // What your character is casting: the action id and how far along it is
    // (seconds in, seconds long), so pets can follow a Teleport or Return in
    // before the screen goes black. 0 when not casting.
    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static int CastInfo(uint* action, float* current, float* total)
    {
        try {
            if (Plugin.Objects.LocalPlayer is not { } p || !p.IsCasting) return 0;
            *action = p.CastActionId;
            *current = p.CurrentCastTime;
            *total = p.TotalCastTime;
            return 1;
        } catch { return 0; }
    }

    // Time of day (seconds), rain amount and weather id, for light-reactive panels.
    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static int GetEnvironment(float* dayTimeSeconds, float* rain, byte* weather)
    {
        try {
            var env = FFXIVClientStructs.FFXIV.Client.Graphics.Environment.EnvManager.Instance();
            if (env == null) return 0;
            *dayTimeSeconds = env->DayTimeSeconds;
            *rain = env->EnvState.Rain;
            *weather = env->ActiveWeather;
            return 1;
        } catch { return 0; }
    }

    // Game lights cast by world panels: a Scene.Light made the way RealTorch and
    // Housingway make theirs outside GPose.
    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static nint LightCreate(int shape)
    {
        try {
            var l = SceneLight.Create((FFXIVClientStructs.FFXIV.Client.Graphics.Render.LightShape)shape, "Ghostty.PanelLight");
            if (l == null || l->RenderLight == null) return 0;
            var r = l->RenderLight;
            l->IsVisible = false;
            r->Transform = (FFXIVClientStructs.FFXIV.Client.Graphics.Transform*)&l->Position;
            r->FalloffType = FFXIVClientStructs.FFXIV.Client.Graphics.Render.LightFalloffType.Quadratic;
            r->FalloffFactor = 1f;
            r->CharacterShadowRange = 110f;
            r->ShadowPlaneNear = 0.01f;
            r->ShadowPlaneFar = 17f;
            return (nint)l;
        } catch { return 0; }
    }

    // visible: 0 hidden, 1 shown, 3 shown casting shadows
    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static int LightUpdate(nint light, float x, float y, float z, float red, float green, float blue, float intensity, float range, int visible)
    {
        try {
            var l = (SceneLight*)light;
            if (l == null || l->RenderLight == null) return 0;
            var r = l->RenderLight;
            l->Position = new System.Numerics.Vector3(x, y, z);
            r->Color = new System.Numerics.Vector3(red, green, blue);
            r->Intensity = intensity;
            r->Range = range;
            r->LightFlags = (visible & 2) != 0
                ? RenderLightFlags.SpecularHighlights | RenderLightFlags.DynamicShadows | RenderLightFlags.CharacterShadows | RenderLightFlags.ObjectShadows
                : RenderLightFlags.SpecularHighlights;
            l->UpdateCulling();
            l->UpdateMaterials();
            bool show = (visible & 1) != 0;
            if (l->IsVisible != show) { l->IsVisible = show; l->UpdateRender(); }
            return 1;
        } catch { return 0; }
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static int LightDestroy(nint light)
    {
        try {
            // the game tears its scene down itself when it exits
            if (light == 0 || Plugin.GameFramework.IsFrameworkUnloading) return 0;
            var l = (SceneLight*)light;
            l->CleanupRender();
            l->Dtor(1);
            return 1;
        } catch { return 0; }
    }

    // Shadow boards behind world panels: a client-side BgObject, made and freed
    // the way Stagehand (LiveObjectService, LiveBgObject), Anyder and Brio do.
    // BgObject.Create(path, pool, existing) as FFXIVClientStructs signs it.
    private const string BgCreateSignature = "E8 ?? ?? ?? ?? 48 89 43 30 48 8B D7";
    private static delegate* unmanaged<byte*, byte*, BgObject*, BgObject*> _bgCreate;

    private static bool ResolveBgCreate()
    {
        try {
            if (!Plugin.Sigs.TryScanText(BgCreateSignature, out nint address)) {
                Plugin.Log.Warning("BgObject.Create not found; world panel shadows stay off");
                return false;
            }
            _bgCreate = (delegate* unmanaged<byte*, byte*, BgObject*, BgObject*>)address;
            return true;
        } catch { return false; }
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static nint BgCreate(byte* path)
    {
        try {
            if (path == null || _bgCreate == null) return 0;
            fixed (byte* pool = "Ghostty.PanelShadow\0"u8) return (nint)_bgCreate(path, pool, null);
        } catch { return 0; }
    }

    // 1 once the model has loaded (ResourceHandle.LoadState 7): only then may transforms be applied
    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static int BgReady(nint obj)
    {
        try {
            var o = (BgObject*)obj;
            return o != null && o->ModelResourceHandle != null && o->ModelResourceHandle->LoadState == 7 ? 1 : 0;
        } catch { return 0; }
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static int BgSetTransform(nint obj, float x, float y, float z, float qx, float qy, float qz, float qw, float sx, float sy, float sz)
    {
        try {
            var o = (BgObject*)obj;
            if (o == null || o->ModelResourceHandle == null || o->ModelResourceHandle->LoadState != 7) return 0;
            o->Position = new System.Numerics.Vector3(x, y, z);
            o->Rotation = new System.Numerics.Quaternion(qx, qy, qz, qw);
            o->Scale = new System.Numerics.Vector3(sx, sy, sz);
            o->UpdateTransforms(false);
            o->UpdateCulling();
            return 1;
        } catch { return 0; }
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static int BgSetTransparency(nint obj, float transparency)
    {
        try {
            var o = (BgObject*)obj;
            if (o == null) return 0;
            o->SetTransparency(transparency);
            return 1;
        } catch { return 0; }
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static int BgDestroy(nint obj)
    {
        try {
            // the game tears its scene down itself when it exits
            if (obj == 0 || Plugin.GameFramework.IsFrameworkUnloading) return 0;
            var o = (BgObject*)obj;
            o->CleanupRender();
            o->Dtor(1);
            return 1;
        } catch { return 0; }
    }

    // 1 while the game has the character inside a housing interior (rain never reaches there).
    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static int Indoor()
    {
        try {
            var h = FFXIVClientStructs.FFXIV.Client.Game.HousingManager.Instance();
            return h != null && h->IndoorTerritory != null ? 1 : 0;
        } catch { return 0; }
    }

    // Characters within NearbyReach yalms of yours, nearest first (players,
    // battle and event NPCs, chocobos; not you): position and hitbox radius.
    // The object table is walked at most every NearbyEvery seconds and the
    // answer kept, so a pet asking every frame costs a copy. Called from the
    // plugin's Draw, on the game's main thread, as GetObject is.
    private const float NearbyReach = 15f;
    private const double NearbyEvery = 0.1;
    private const int NearbyMax = 32;
    private static readonly GuCharacter[] NearbyCache = new GuCharacter[NearbyMax];
    private static int nearbyCount;
    private static long nearbyAt;

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static int NearbyCharacters(GuCharacter* outp, int cap)
    {
        try {
            long now = System.Diagnostics.Stopwatch.GetTimestamp();
            if (now - nearbyAt > (long)(NearbyEvery * System.Diagnostics.Stopwatch.Frequency)) {
                nearbyAt = now;
                nearbyCount = 0;
                if (Plugin.Objects.LocalPlayer is { } me) {
                    var at = me.Position;
                    var found = new System.Collections.Generic.List<(float d, GuCharacter c)>(16);
                    foreach (var o in Plugin.Objects) {
                        if (o == null || o.Address == me.Address) continue;
                        var k = o.ObjectKind;
                        if (k != Dalamud.Game.ClientState.Objects.Enums.ObjectKind.Pc
                            && k != Dalamud.Game.ClientState.Objects.Enums.ObjectKind.BattleNpc
                            && k != Dalamud.Game.ClientState.Objects.Enums.ObjectKind.EventNpc
                            && k != Dalamud.Game.ClientState.Objects.Enums.ObjectKind.Companion) continue;
                        if (!o.IsTargetable && k != Dalamud.Game.ClientState.Objects.Enums.ObjectKind.Pc) continue;
                        float dx = o.Position.X - at.X, dz = o.Position.Z - at.Z;
                        float d = MathF.Sqrt(dx * dx + dz * dz);
                        if (d > NearbyReach) continue;
                        found.Add((d, new GuCharacter {
                            X = o.Position.X, Y = o.Position.Y, Z = o.Position.Z,
                            Radius = MathF.Max(o.HitboxRadius, 0.3f), EntityId = o.GameObjectId,
                            Height = ((FFXIVClientStructs.FFXIV.Client.Game.Object.GameObject*)o.Address)->Height,
                            Kind = k switch {
                                Dalamud.Game.ClientState.Objects.Enums.ObjectKind.Pc => 1,
                                Dalamud.Game.ClientState.Objects.Enums.ObjectKind.BattleNpc => 2,
                                Dalamud.Game.ClientState.Objects.Enums.ObjectKind.EventNpc => 3,
                                _ => 4,
                            },
                        }));
                    }
                    found.Sort((a, b) => a.d.CompareTo(b.d));
                    for (int i = 0; i < found.Count && i < NearbyMax; i++) NearbyCache[nearbyCount++] = found[i].c;
                }
            }
            int n = Math.Min(nearbyCount, cap);
            for (int i = 0; i < n; i++) outp[i] = NearbyCache[i];
            return n;
        } catch { return 0; }
    }

    // The same ray through the game's collision with a choice of filter, for
    // pets (lua/world.lua): which colliders count is what decides whether a
    // pet sees a lamp post. BGCollisionModule's own helper (mode 0, `Raycast`
    // above) asks for layer 1 and materials with bit 0x4000 set, which is what
    // ScreenToWorld wants (ground you can click) and misses props the player
    // still bumps into. mode 1: every layer, any non-zero material. mode 2:
    // every layer, the helper's material filter (to tell layer from material).
    // 1 with the first hit within `max` yalms, else 0.
    [UnmanagedCallersOnly(CallConvs = [typeof(System.Runtime.CompilerServices.CallConvCdecl)])]
    private static int RaycastMode(float ox, float oy, float oz, float dx, float dy, float dz, float max, int mode,
                                   float* hx, float* hy, float* hz)
    {
        try {
            var fw = FFXIVClientStructs.FFXIV.Client.System.Framework.Framework.Instance();
            if (fw == null || fw->BGCollisionModule == null) return 0;
            var o = new System.Numerics.Vector3(ox, oy, oz);
            var d = new System.Numerics.Vector3(dx, dy, dz);
            var hit = default(FFXIVClientStructs.FFXIV.Common.Component.BGCollision.RaycastHit);
            int* flags = stackalloc int[4];
            int layers;
            if (mode == 1) { flags[0] = -1; flags[1] = -1; flags[2] = 0; flags[3] = 0; layers = -1; }        // mask all, value 0: any material
            else if (mode == 2) { flags[0] = 0x4000; flags[1] = 0; flags[2] = 0x4000; flags[3] = 0; layers = -1; }
            else { flags[0] = 0x4000; flags[1] = 0; flags[2] = 0x4000; flags[3] = 0; layers = 1; }
            if (!fw->BGCollisionModule->RaycastMaterialFilter(&hit, &o, &d, max, layers, flags)) return 0;
            *hx = hit.Point.X; *hy = hit.Point.Y; *hz = hit.Point.Z;
            return 1;
        } catch { return 0; }
    }

    // First hit of a ray against the game's collision scene (what IGameGui.ScreenToWorld casts against).
    [UnmanagedCallersOnly(CallConvs = [typeof(System.Runtime.CompilerServices.CallConvCdecl)])]
    private static int Raycast(float ox, float oy, float oz, float dx, float dy, float dz, float max, float* hx, float* hy, float* hz)
    {
        try {
            if (!FFXIVClientStructs.FFXIV.Common.Component.BGCollision.BGCollisionModule.RaycastMaterialFilter(
                    new System.Numerics.Vector3(ox, oy, oz), new System.Numerics.Vector3(dx, dy, dz), out var hit, max)) return 0;
            *hx = hit.Point.X; *hy = hit.Point.Y; *hz = hit.Point.Z;
            return 1;
        } catch { return 0; }
    }
}

// POST the file at `path` (or, without one, `bytes`) to `url` (the core only passes https
// links) as `contentType`, with `headers` ("Name: value" lines) when given, off the game's
// threads. The answer comes back as GuEvent.HttpDone: a = id, b = the HTTP
// status (0: no answer, -1: the file could not be read), text = the start of the body or
// the error. Nothing is posted once the plugin is unloading. (Outside HostApi, which is
// unsafe: async code cannot run in an unsafe context.)
internal static class GalleryUpload
{
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(90) };
    private static readonly object Gate = new();
    private static readonly CancellationTokenSource StopSource = new();
    private static bool _open = true;

    // What the core keeps of an answer: its event text holds 1023 bytes (255 before the
    // sign-in, where a longer answer is only cut shorter).
    private const int AnswerMax = 1000;

    public static void Start(int id, string url, string? path, string contentType,
        string? headers = null, byte[]? bytes = null)
    {
        CancellationToken stop = StopSource.Token;
        _ = Task.Run(async () => {
            int status;
            string text;
            try {
                byte[] body = path != null ? await File.ReadAllBytesAsync(path, stop) : bytes ?? Array.Empty<byte>();
                using var content = new ByteArrayContent(body);
                content.Headers.ContentType = new MediaTypeHeaderValue(contentType);
                using var req = new HttpRequestMessage(HttpMethod.Post, url) { Content = content };
                req.Headers.TryAddWithoutValidation("X-Ghostty-Client", "GhosttyDalamud");
                foreach (string line in (headers ?? string.Empty).Split('\n', StringSplitOptions.RemoveEmptyEntries))
                {
                    int colon = line.IndexOf(':');
                    if (colon > 0) req.Headers.TryAddWithoutValidation(line[..colon].Trim(), line[(colon + 1)..].Trim());
                }
                using var res = await Http.SendAsync(req, stop);
                status = (int)res.StatusCode;
                text = await res.Content.ReadAsStringAsync(stop);
            } catch (OperationCanceledException) when (stop.IsCancellationRequested) {
                return;
            } catch (Exception e) when (e is IOException or UnauthorizedAccessException) {
                status = -1; // the screenshot could not be read
                text = e.Message;
            } catch (Exception e) {
                status = 0; // no answer: offline, DNS, TLS, timeout
                text = e.Message;
            }
            if (text.Length > AnswerMax) text = text[..AnswerMax];
            lock (Gate) { if (_open) Native.Post(GuEvent.HttpDone, id, status, 0, 0, text); }
        });
    }

    public static void Stop()
    {
        lock (Gate) _open = false;
        try { StopSource.Cancel(); } catch { /* already stopped */ }
    }
}
