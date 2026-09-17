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

    public static string StatusText()
    {
        byte* buf = stackalloc byte[128];
        nuint n = Status(buf, 128);
        return Encoding.UTF8.GetString(buf, (int)n);
    }
}
