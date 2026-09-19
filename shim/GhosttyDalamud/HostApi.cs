// GuHostApi callbacks: Dalamud and game facilities handed to the core. Each
// one only reads, writes or calls; anything that can throw returns 0 instead.
using System;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using Dalamud.Game.ClientState.GamePad;
using Dalamud.Game.ClientState.Keys;
using Dalamud.Game.Command;
using Dalamud.Game.Gui.Dtr;
using Dalamud.Interface.ManagedFontAtlas;
using RenderLightFlags = FFXIVClientStructs.FFXIV.Client.Graphics.Render.LightFlags;
using SceneLight = FFXIVClientStructs.FFXIV.Client.Graphics.Scene.Light;
using BgObject = FFXIVClientStructs.FFXIV.Client.Graphics.Scene.BgObject;

namespace GhosttyDalamud;

internal static unsafe class HostApi
{
    public static GuHostApi* Api { get; private set; }

    private static IDisposable? _fontScope;
    private static IFontHandle? _worldFont;
    private static IDtrBarEntry? _dtr;

    public static void Create()
    {
        // a large mono font for world panels: glyphs get minified instead of magnified
        _worldFont = Plugin.Pi.UiBuilder.FontAtlas.NewDelegateFontHandle(e => e.OnPreBuild(tk =>
            tk.AddDalamudAssetFont(Dalamud.DalamudAsset.InconsolataRegular, new SafeFontConfig { SizePx = 40 })));

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
        Api->TextureFile    = &TextureFile;
    }

    public static void Free()
    {
        NativeMemory.Free(Api);
        Api = null;
        _worldFont?.Dispose();
        _worldFont = null;
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

    // Fonts and keys -----------------------------------------------------------------------------

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static void PushMonoFont()
    {
        _fontScope = Plugin.Pi.UiBuilder.MonoFontHandle.Push();
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static void PushWorldFont()
    {
        _fontScope = _worldFont is { Available: true } ? _worldFont.Push() : Plugin.Pi.UiBuilder.MonoFontHandle.Push();
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
