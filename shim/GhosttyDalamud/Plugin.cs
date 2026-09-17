// Dalamud adapter. Configuration resolves against the original installation;
// native loading uses an isolated writable cache owned by this plugin instance.
using System;
using System.Runtime.InteropServices;
using Dalamud.Game.ClientState.Objects;
using Dalamud.IoC;
using Dalamud.Plugin;
using Dalamud.Plugin.Services;

namespace GhosttyDalamud;

public sealed unsafe class Plugin : IDalamudPlugin
{
    [PluginService] internal static IDalamudPluginInterface Pi { get; private set; } = null!;
    [PluginService] internal static ICommandManager Commands { get; private set; } = null!;
    [PluginService] internal static IPluginLog Log { get; private set; } = null!;
    [PluginService] internal static IDtrBar Dtr { get; private set; } = null!;
    [PluginService] internal static IKeyState Keys { get; private set; } = null!;
    [PluginService] internal static IGamepadState Gamepad { get; private set; } = null!;
    [PluginService] internal static IObjectTable Objects { get; private set; } = null!;
    [PluginService] internal static ITargetManager Targets { get; private set; } = null!;
    [PluginService] internal static IClientState Client { get; private set; } = null!;
    [PluginService] internal static ICondition Condition { get; private set; } = null!;
    [PluginService] internal static ISigScanner Sigs { get; private set; } = null!;
    [PluginService] internal static IGameInteropProvider Interop { get; private set; } = null!;
    [PluginService] internal static IGameConfig GameConfig { get; private set; } = null!;
    [PluginService] internal static IFramework GameFramework { get; private set; } = null!;

    private NativeCache? nativeCache;
    private bool nativeLoaded;
    private bool hostCreated;
    private bool walkHooked;
    private bool subscribed;
    private bool disposed;

    public Plugin()
    {
        nint installDir = 0, configDir = 0, configsRoot = 0;
        try
        {
            string install = Pi.AssemblyLocation.DirectoryName!;
            nativeCache = new NativeCache(install, Pi.ConfigDirectory.FullName);
            Native.Load(nativeCache.CorePath);
            nativeLoaded = true;
            HostApi.Create();
            hostCreated = true;
            installDir = Marshal.StringToCoTaskMemUTF8(install);
            configDir = Marshal.StringToCoTaskMemUTF8(Pi.ConfigDirectory.FullName);
            configsRoot = Marshal.StringToCoTaskMemUTF8(Pi.ConfigDirectory.Parent!.FullName);
            var info = new GuInitInfo {
                Size = (nuint)sizeof(GuInitInfo),
                HostKind = Native.HostKindDalamud,
                InstallDir = (byte*)installDir,
                ConfigDir = (byte*)configDir,
                ConfigsRoot = (byte*)configsRoot,
            };
            if (Native.InitEx(HostApi.Api, &info) == 1)
                throw new InvalidOperationException("Native core rejected initialization arguments.");
            walkHooked = true;
            HostApi.HookWalkInput();
            Pi.UiBuilder.Draw += OnDraw;
            Pi.UiBuilder.OpenMainUi += OnOpenMain;
            Pi.UiBuilder.OpenConfigUi += OnOpenConfig;
            Pi.ActivePluginsChanged += OnPluginsChanged;
            subscribed = true;
        }
        catch
        {
            Dispose();
            throw;
        }
        finally
        {
            Marshal.FreeCoTaskMem(installDir);
            Marshal.FreeCoTaskMem(configDir);
            Marshal.FreeCoTaskMem(configsRoot);
        }
    }

    private void OnDraw()
    {
        string? error = nativeCache?.Refresh();
        if (error != null) Log.Warning("Ghostty native cache update: " + error);
        Native.Frame();
    }
    private static void OnOpenMain() => Native.Post(GuEvent.OpenMain, 0, 0, 0, 0, string.Empty);
    private static void OnOpenConfig() => Native.Post(GuEvent.OpenConfig, 0, 0, 0, 0, string.Empty);
    private static void OnPluginsChanged(IActivePluginsChangedEventArgs args) => Native.Post(GuEvent.PluginsChanged, 0, 0, 0, 0, string.Empty);

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        if (subscribed)
        {
            Pi.UiBuilder.Draw -= OnDraw;
            Pi.UiBuilder.OpenMainUi -= OnOpenMain;
            Pi.UiBuilder.OpenConfigUi -= OnOpenConfig;
            Pi.ActivePluginsChanged -= OnPluginsChanged;
        }
        try
        {
            if (walkHooked) HostApi.UnhookWalkInput();
            if (nativeLoaded)
            {
                Native.Shutdown();
                Native.Unload();
            }
        }
        finally
        {
            if (hostCreated) HostApi.Free();
            nativeCache?.Dispose();
        }
    }
}
