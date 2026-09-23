// P/Invoke surface of ghostty_core.dll and the structs shared with it. No
// logic here: one function pointer per export, resolved when the plugin loads.
using System;
using System.Runtime.InteropServices;
using System.Text;

namespace GhosttyDalamud;

// Field order mirrors GuHostApi in core/app/state.nelua; append only.
[StructLayout(LayoutKind.Sequential)]
internal unsafe struct GuHostApi
{
    public nuint Size;
    public delegate* unmanaged[Cdecl]<int, byte*, void> Log;
    public delegate* unmanaged[Cdecl]<void> PushMonoFont;
    public delegate* unmanaged[Cdecl]<void> PopFont;
    public delegate* unmanaged[Cdecl]<int, void> ConsumeKey;
    public delegate* unmanaged[Cdecl]<byte*, void*> ResolveImGui;
    public delegate* unmanaged[Cdecl]<int, int> GamepadPressed;
    public delegate* unmanaged[Cdecl]<int, int> GamepadDown;
    public delegate* unmanaged[Cdecl]<GuCamera*, int> GetCamera;
    public delegate* unmanaged[Cdecl]<int, ulong, GuObject*, int> GetObject;
    public delegate* unmanaged[Cdecl]<float, int> SetRotation;
    public delegate* unmanaged[Cdecl]<byte*, byte*, ushort*, ushort*, int> AnimGet;
    public delegate* unmanaged[Cdecl]<byte, byte, ushort, int, int> AnimSet;
    public delegate* unmanaged[Cdecl]<ushort, int> AnimPlay;
    public delegate* unmanaged[Cdecl]<uint, float, int> AnimSpeed;
    public delegate* unmanaged[Cdecl]<float*, float*, byte*, int> GetEnvironment;
    public delegate* unmanaged[Cdecl]<void> PushWorldFont;
    public delegate* unmanaged[Cdecl]<float*, float*, float*, float*, int> GetCameraState;
    public delegate* unmanaged[Cdecl]<float, float, float, int> SetCameraState;
    public delegate* unmanaged[Cdecl]<int, nint> LightCreate;
    public delegate* unmanaged[Cdecl]<nint, float, float, float, float, float, float, float, float, int, int> LightUpdate;
    public delegate* unmanaged[Cdecl]<nint, int> LightDestroy;
    public delegate* unmanaged[Cdecl]<int, float, float, float, int> SetLookAt;
    public delegate* unmanaged[Cdecl]<byte*, byte*, int> CommandAdd;
    public delegate* unmanaged[Cdecl]<byte*, int> CommandRemove;
    public delegate* unmanaged[Cdecl]<byte*, byte*, byte*, int, int> DtrSet;
    public delegate* unmanaged[Cdecl]<void> DtrRemove;
    public delegate* unmanaged[Cdecl]<int, void> SetUiHide;
    public delegate* unmanaged[Cdecl]<byte*, int> PluginLoaded;
    public delegate* unmanaged[Cdecl]<int> IpcRegister;
    public delegate* unmanaged[Cdecl]<void> IpcUnregister;
    public delegate* unmanaged[Cdecl]<float, float, float, float, float, float, float, float*, float*, float*, int> Raycast;
    public delegate* unmanaged[Cdecl]<GuSceneDepth*, int> GetSceneDepth;
    public delegate* unmanaged[Cdecl]<byte*, int> OpenUrl;
    public delegate* unmanaged[Cdecl]<byte*, nint> BgCreate;
    public delegate* unmanaged[Cdecl]<nint, int> BgReady;
    public delegate* unmanaged[Cdecl]<nint, float, float, float, float, float, float, float, float, float, float, int> BgSetTransform;
    public delegate* unmanaged[Cdecl]<nint, float, int> BgSetTransparency;
    public delegate* unmanaged[Cdecl]<nint, int> BgDestroy;
    public delegate* unmanaged[Cdecl]<byte*, byte*, int, int> CommandAddTagged;
    public delegate* unmanaged[Cdecl]<byte*, int> ChatPrint;
    public delegate* unmanaged[Cdecl]<byte*, float*, float*, float*, float*, int> AddonRect;
    public delegate* unmanaged[Cdecl]<byte*, int, int> AddonShow;
    public delegate* unmanaged[Cdecl]<byte*, int> ChatSend;
    public delegate* unmanaged[Cdecl]<byte*, uint*, int> ConfigUInt;
    public delegate* unmanaged[Cdecl]<byte*, uint*, uint*, nint> TextureFile;
    public delegate* unmanaged[Cdecl]<int> SceneFlags;
    public delegate* unmanaged[Cdecl]<int, byte*, byte*, byte*, int> HttpUpload;
    public delegate* unmanaged[Cdecl]<byte*, byte*, nuint, nuint> GameString;
    public delegate* unmanaged[Cdecl]<GuHudRect*, int, int> HudRects;
    public delegate* unmanaged[Cdecl]<int, byte*, byte*, byte*, byte*, byte*, nuint, int> HttpPost;
    public delegate* unmanaged[Cdecl]<int> Indoor;
    // a terminal in a game window (NativeWindows.cs, docs/NATIVE_UI.md)
    public delegate* unmanaged[Cdecl]<int, byte*, float, float, float, float, int> NativeOpen;
    public delegate* unmanaged[Cdecl]<int, int> NativeClose;
    public delegate* unmanaged[Cdecl]<int, GuNativeState*, int> NativeState;
    public delegate* unmanaged[Cdecl]<int, void*, int, int, int, int, float, float, float, float, int> NativeDraw;
    public delegate* unmanaged[Cdecl]<int, float, float, int> NativeResize;
    public delegate* unmanaged[Cdecl]<int, byte*, int> NativeTitle;
    public delegate* unmanaged[Cdecl]<float, int> PushMonoFontPx;
}

// Mirrors GuNativeState in core/nativewin.nelua.
[StructLayout(LayoutKind.Sequential)]
internal struct GuNativeState
{
    public int Status;            // 0 none, 1 opening (id 0: starting), 2 open (id 0: ready), 3 closed, 4 failed
    public float X, Y;            // the addon's screen position
    public float W, H;            // its size in UI units
    public float Scale;           // screen pixels per UI unit
    public float Cx, Cy, Cw, Ch;  // the content area, UI units from the addon's origin
    public int Hovered;           // the game's addon under the pointer is this one
    public int Focused;           // the game has it focused
    public int UiHidden;          // the game's UI is hidden, or this addon is not shown
    public int Closes;            // times the game closed it
    public int Error;             // NATIVE_ERR_* of the last failure
}

// Mirrors GuHudRect in core/hudmask.nelua.
[StructLayout(LayoutKind.Sequential)]
internal unsafe struct GuHudRect
{
    public float X, Y, W, H;
    public fixed byte Name[32];
}

// Mirrors GuInitInfo in core/app/boot.nelua.
[StructLayout(LayoutKind.Sequential)]
internal unsafe struct GuInitInfo
{
    public nuint Size;
    public int HostKind;
    public byte* InstallDir;
    public byte* ConfigDir;
    public byte* ConfigsRoot;
}

// Layouts mirror GuCamera/GuObject in core/world.nelua.
[StructLayout(LayoutKind.Sequential)]
internal struct GuCamera
{
    public System.Numerics.Matrix4x4 ViewProjection;
    public float Width;
    public float Height;
}

// Mirrors GuSceneDepth in core/depthpass.nelua. Borrowed pointers.
[StructLayout(LayoutKind.Sequential)]
internal struct GuSceneDepth
{
    public nint Srv;
    public nint UiDevice;
    public uint ActualWidth, ActualHeight;
    public uint AllocatedWidth, AllocatedHeight;
}

[StructLayout(LayoutKind.Sequential)]
internal struct GuObject
{
    public float X, Y, Z, Rotation;
    public ulong EntityId;
    public uint Territory;
    public int Found;
    public int InCombat;
    public float Height;
    public float HitboxRadius;
    public int Mounted;
}

// GuEventKind in core/app/hostsurface.nelua.
internal enum GuEvent
{
    Chat = 1,
    OpenMain = 2,
    OpenConfig = 3,
    DtrClick = 4,
    PluginsChanged = 5,
    HttpDone = 6,
}

internal static unsafe class Native
{
    public const int HostKindDalamud = 1;

    private static nint _lib;

    public static delegate* unmanaged[Cdecl]<GuHostApi*, GuInitInfo*, int> InitEx;
    public static delegate* unmanaged[Cdecl]<void> Frame;
    public static delegate* unmanaged[Cdecl]<int, int, int, float, float, byte*, void> Event;
    public static delegate* unmanaged[Cdecl]<nint, float, float, float, float, int, void> PopupDraw;
    public static delegate* unmanaged[Cdecl]<void> PopupReset;
    public static delegate* unmanaged[Cdecl]<int*, int*, void> PopupSize;
    public static delegate* unmanaged[Cdecl]<byte*, nuint, nuint> Status;
    public static delegate* unmanaged[Cdecl]<void> Shutdown;
    public static delegate* unmanaged[Cdecl]<byte*> Version;
    public static delegate* unmanaged[Cdecl]<float*, float*, int, int, void> WalkInput;
    // optional: a core (or loader) from before GhosttyDalamud.v1.Call has none
    public static delegate* unmanaged[Cdecl]<byte*, byte*, nuint, nuint> Call;
    // optional: a core (or loader) from before the chat pet has none
    public static delegate* unmanaged[Cdecl]<int, byte*, byte*, void> Chat;

    public static void Load(string dllPath)
    {
        // ghostty_loader.dll (core/loader.nelua) runs a copy of the core and swaps it when the file changes
        string loader = System.IO.Path.Combine(System.IO.Path.GetDirectoryName(dllPath)!, "ghostty_loader.dll");
        nint lib = NativeLibrary.Load(System.IO.File.Exists(loader) ? loader : dllPath);
        // resolve every export before publishing any: a missing one frees the
        // library and leaves nothing half-loaded behind
        try
        {
            nint initEx     = NativeLibrary.GetExport(lib, "gu_init_ex");
            nint frame      = NativeLibrary.GetExport(lib, "gu_frame");
            nint evt        = NativeLibrary.GetExport(lib, "gu_event");
            nint popupDraw  = NativeLibrary.GetExport(lib, "gu_popup_draw");
            nint popupReset = NativeLibrary.GetExport(lib, "gu_popup_reset");
            nint popupSize  = NativeLibrary.GetExport(lib, "gu_popup_size");
            nint status     = NativeLibrary.GetExport(lib, "gu_status");
            nint shutdown   = NativeLibrary.GetExport(lib, "gu_shutdown");
            nint version    = NativeLibrary.GetExport(lib, "gu_version");
            nint walkInput  = NativeLibrary.GetExport(lib, "gu_walk_input");
            NativeLibrary.TryGetExport(lib, "gu_call", out nint call);
            NativeLibrary.TryGetExport(lib, "gu_chat", out nint chat);
            InitEx     = (delegate* unmanaged[Cdecl]<GuHostApi*, GuInitInfo*, int>)initEx;
            Frame      = (delegate* unmanaged[Cdecl]<void>)frame;
            Event      = (delegate* unmanaged[Cdecl]<int, int, int, float, float, byte*, void>)evt;
            PopupDraw  = (delegate* unmanaged[Cdecl]<nint, float, float, float, float, int, void>)popupDraw;
            PopupReset = (delegate* unmanaged[Cdecl]<void>)popupReset;
            PopupSize  = (delegate* unmanaged[Cdecl]<int*, int*, void>)popupSize;
            Status     = (delegate* unmanaged[Cdecl]<byte*, nuint, nuint>)status;
            Shutdown   = (delegate* unmanaged[Cdecl]<void>)shutdown;
            Version    = (delegate* unmanaged[Cdecl]<byte*>)version;
            WalkInput  = (delegate* unmanaged[Cdecl]<float*, float*, int, int, void>)walkInput;
            Call       = (delegate* unmanaged[Cdecl]<byte*, byte*, nuint, nuint>)call;
            Chat       = (delegate* unmanaged[Cdecl]<int, byte*, byte*, void>)chat;
            _lib       = lib;
        }
        catch
        {
            NativeLibrary.Free(lib);
            throw;
        }
    }

    public static void Unload()
    {
        NativeLibrary.Free(_lib);
        _lib = 0;
    }

    // gu_event with the text as NUL-terminated UTF-8.
    public static void Post(GuEvent kind, int a, int b, float x, float y, string text)
    {
        byte[] bytes = Encoding.UTF8.GetBytes(text + "\0");
        fixed (byte* p = bytes) Event((int)kind, a, b, x, y, p);
    }

    // gu_chat: one chat message, sender and text as NUL-terminated UTF-8.
    public static void PostChat(int kind, string sender, string text)
    {
        if (Chat == null) return;
        byte[] s = Encoding.UTF8.GetBytes(sender + "\0");
        byte[] t = Encoding.UTF8.GetBytes(text + "\0");
        fixed (byte* ps = s) fixed (byte* pt = t) Chat(kind, ps, pt);
    }

    // gu_call: JSON in, JSON out (docs/IPC.md). The core answers in at most
    // CallMax bytes (a larger answer comes back as a "response too large" error).
    public const int CallMax = 65536;

    public static string CallJson(string request)
    {
        byte[] req = Encoding.UTF8.GetBytes(request + "\0");
        byte[] buf = System.Buffers.ArrayPool<byte>.Shared.Rent(CallMax);
        try
        {
            fixed (byte* r = req) fixed (byte* b = buf)
            {
                nuint n = Call(r, b, (nuint)CallMax);
                return Encoding.UTF8.GetString(b, (int)n);
            }
        }
        finally { System.Buffers.ArrayPool<byte>.Shared.Return(buf); }
    }

    public static string StatusText()
    {
        byte* buf = stackalloc byte[128];
        nuint n = Status(buf, 128);
        return Encoding.UTF8.GetString(buf, (int)n);
    }
}
