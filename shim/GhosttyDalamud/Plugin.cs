// GhosttyDalamud: an ordinary Dalamud plugin around the Nelua core. It loads
// ghostty_core.dll from beside this assembly, forwards the draw tick and the
// /xlplugins buttons, and hands Dalamud to the core through GuHostApi
// (HostApi.cs). The core decides what to register and when; see
// core/app/hostsurface.nelua.
using System.IO;
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
    [PluginService] internal static IChatGui Chat { get; private set; } = null!;
    [PluginService] internal static IGameGui GameGui { get; private set; } = null!;

    public Plugin()
    {
        // Dalamud loads the managed assembly from memory, but AssemblyLocation
        // still names the plugin folder; the native core and lua/ sit there.
        string install = Pi.AssemblyLocation.DirectoryName!;
        Native.Load(Path.Combine(install, "ghostty_core.dll"));
        HostApi.Create();

        // the core copies these strings during init
        nint installDir  = Marshal.StringToCoTaskMemUTF8(install);
        nint configDir   = Marshal.StringToCoTaskMemUTF8(Pi.ConfigDirectory.FullName);
        nint configsRoot = Marshal.StringToCoTaskMemUTF8(Pi.ConfigDirectory.Parent!.FullName);
        var info = new GuInitInfo {
            Size        = (nuint)sizeof(GuInitInfo),
            HostKind    = Native.HostKindDalamud,
            InstallDir  = (byte*)installDir,
            ConfigDir   = (byte*)configDir,
            ConfigsRoot = (byte*)configsRoot,
        };
        Native.InitEx(HostApi.Api, &info); // the core logs why it is not active yet, and retries
        Marshal.FreeCoTaskMem(installDir);
        Marshal.FreeCoTaskMem(configDir);
        Marshal.FreeCoTaskMem(configsRoot);

        HostApi.HookWalkInput();
        Pi.UiBuilder.Draw         += OnDraw;
        Pi.UiBuilder.OpenMainUi   += OnOpenMain;
        Pi.UiBuilder.OpenConfigUi += OnOpenConfig;
        Pi.ActivePluginsChanged   += OnPluginsChanged;
        if (Native.Chat != null) Chat.ChatMessageUnhandled += OnChat;
    }

    private static void OnDraw() => Native.Frame();
    private static void OnOpenMain() => Native.Post(GuEvent.OpenMain, 0, 0, 0, 0, string.Empty);
    private static void OnOpenConfig() => Native.Post(GuEvent.OpenConfig, 0, 0, 0, 0, string.Empty);
    private static void OnPluginsChanged(IActivePluginsChangedEventArgs args) => Native.Post(GuEvent.PluginsChanged, 0, 0, 0, 0, string.Empty);

    // every line the chat log shows, as plain text, for the chat pet (core/app/chatpanel.nelua)
    private static void OnChat(Dalamud.Game.Chat.IChatMessage m)
    {
        try { Native.PostChat((int)m.LogKind, m.Sender?.TextValue ?? string.Empty, m.Message?.TextValue ?? string.Empty); }
        catch { /* never break the chat */ }
    }

    public void Dispose()
    {
        Pi.UiBuilder.Draw         -= OnDraw;
        Pi.UiBuilder.OpenMainUi   -= OnOpenMain;
        Pi.UiBuilder.OpenConfigUi -= OnOpenConfig;
        Pi.ActivePluginsChanged   -= OnPluginsChanged;
        Chat.ChatMessageUnhandled -= OnChat;
        HostApi.UnhookWalkInput(); // before the core it calls goes away
        Native.Shutdown();         // the core removes its commands, info bar entry and IPC first
        Native.Unload();
        HostApi.Free();
    }
}
