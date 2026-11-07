using System.Collections.Concurrent;
using XivHud.Protocol;
using Dalamud.Game.Command;
using Dalamud.Game.Gui.Dtr;
using Dalamud.Plugin;
using Dalamud.Plugin.Ipc;
using Dalamud.Plugin.Services;

namespace XivHud.Character;

internal sealed class Plugin
{
    private readonly IDalamudPluginInterface pi;
    private readonly ICommandManager commands;
    private readonly IFramework framework;
    private readonly IClientState client;
    private readonly IPluginLog log;
    private readonly Configuration config;
    private readonly CharacterData data = null!;
    private readonly NativeCharacterBridge bridge = null!;
    private readonly CharacterWindow window = null!;
    private readonly ConcurrentQueue<Action> actions = new();
    private readonly ICallGateProvider<object> toggle = null!, settings = null!;
    private readonly ICallGateProvider<bool> ready = null!;
    private readonly HudEndpoint ipc = new("character");
    private ICallGateProvider<string, string>? call;
    private IDtrBarEntry? toolbar;
    private CharacterSnapshot? snapshot;
    private string? unavailable = "Your record will be here when you enter Eorzea.";
    private long nextRead;
    private bool disposed, commandRegistered, wasOpen, drawFailed;
    private readonly object shutdownGate = new();
    private Task? shutdown;

    public Plugin(IDalamudPluginInterface pi, ICommandManager commands, IFramework framework, IClientState client,
        IDataManager dataManager, IAddonLifecycle lifecycle, IDtrBar dtr, IPluginLog log, ITextureProvider textures,
        IGameInteropProvider interop, IObjectTable objects, IPlayerState player, IUnlockState unlocks)
    {
        this.pi = pi; this.commands = commands; this.framework = framework; this.client = client; this.log = log;
        config = GhosttyDalamud.PhoneModules.ModuleConfiguration.Load<Configuration>(pi, "XivHud.Character");
        config.Scale = float.IsFinite(config.Scale) ? Math.Clamp(config.Scale, .8f, 1.5f) : 1;
        config.NativeWindowEnabled = config.WindowHostEnabled = config.ShowToolbarEntry = false;
        try
        {
            data = new(dataManager, player, objects, unlocks);
            bridge = new(lifecycle, framework, log, interop);
            window = new(pi, config, Save, QueueNativeCharacter, QueueArmoury, QueueEquip, textures);
            toggle = pi.GetIpcProvider<object>("XivHud.Character.Toggle");
            settings = pi.GetIpcProvider<object>("XivHud.Character.OpenSettings");
            ready = pi.GetIpcProvider<bool>("XivHud.Character.Ready");
            toggle.RegisterAction(() => actions.Enqueue(window.Toggle));
            settings.RegisterAction(() => actions.Enqueue(window.OpenSettings));
            ready.RegisterFunc(() => !disposed);
            call = pi.GetIpcProvider<string, string>("XivHud.Character.v1.Call");
            call.RegisterFunc(ipc.Call);
            PublishStatus();
            commandRegistered = commands.AddHandler("/xivcharacter", new CommandInfo(OnCommand)
                { HelpMessage = "Open XivHud Character. Options: open, close, settings, screen, frame, world, native, armoury, status." });
            if (!commandRegistered) throw new InvalidOperationException("/xivcharacter is already registered.");
            bridge.ToggleRequested += window.Open;
            bridge.MainCommandToggleRequested += window.Toggle;
            bridge.CanAdopt = () => unavailable is null && snapshot is not null;
            bridge.AdoptNativeOpens = config.ReplaceCharacter;
            toolbar = dtr.Get("XivHud.Character");
            toolbar.Text = "Character";
            toolbar.Tooltip = "Adventurer's Record\nClick to open. Right-click to change its appearance.";
            toolbar.OnClick = e => actions.Enqueue(e.ClickType == MouseClickType.Right ? window.OpenSettings : window.Toggle);
            toolbar.Shown = config.ShowToolbarEntry;
            framework.Update += Update;
            pi.UiBuilder.Draw += Draw;
            
            
            log.Information("XivHud.Character ready. /xivcharacter opens the adventurer's record. Native fallback remains available.");
        }
        catch { DisposeCore(); throw; }
    }

    public Task LoadAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        return Task.CompletedTask;
    }

    private void Save() => GhosttyDalamud.PhoneModules.ModuleConfiguration.Save(pi, "XivHud.Character", config);
    private void QueueNativeCharacter() => actions.Enqueue(() => { bridge.OpenNative(); window.Close(); });
    private void QueueArmoury() => actions.Enqueue(() => { bridge.OpenArmoury(); window.Close(); });
    // EquipGearset is a game action: framework thread only, never from the ImGui draw path.
    private void QueueEquip(int id) => actions.Enqueue(() => window.ShowGearSetResult(id + 1, CharacterData.EquipGearset(id)));
    private void Open() => actions.Enqueue(window.Open);
    private void Settings() => actions.Enqueue(window.OpenSettings);
    private void OnCommand(string command, string args)
    {
        switch (args.Trim().ToLowerInvariant())
        {
            case "open": Open(); break;
            case "close": actions.Enqueue(window.Close); break;
            case "settings": Settings(); break;
            case "screen": actions.Enqueue(() => { config.WindowHostEnabled = false; config.NativeWindowEnabled = false; Save(); window.Open(); }); break;
            case "frame": actions.Enqueue(() => { config.WindowHostEnabled = false; config.NativeWindowEnabled = true; Save(); window.Open(); }); break;
            case "world": actions.Enqueue(() => { config.NativeWindowEnabled = false; config.WindowHostEnabled = true; config.WindowHostPlacement = "Hud"; Save(); window.Open(); }); break;
            case "native": QueueNativeCharacter(); break;
            case "armoury" or "armory": QueueArmoury(); break;
            case "game": actions.Enqueue(bridge.InvokeGameCharacter); break;
            case "status": actions.Enqueue(() => log.Information("XivHud.Character status: open={Open}; job={Job}; gear={Gear}; jobs={Jobs}; sets={Sets}; nativeAdoption={Adopt}; data={Status}; bridge={Bridge}; bridgeError={Error}; controller={Controller}; window={Window}",
                window.IsOpen, snapshot?.Job.Abbreviation ?? "-", snapshot?.Gear.Count(g => !g.IsEmpty) ?? 0, snapshot?.Jobs.Count ?? 0,
                snapshot?.GearSets.Count ?? 0, config.ReplaceCharacter, unavailable ?? "ready", bridge.BridgeState,
                bridge.LastError ?? "none", window.ControllerStatus, window.HostingStatus)); break;
            default: actions.Enqueue(window.Toggle); break;
        }
    }

    private void Update(IFramework _)
    {
        if (disposed) return;
        try
        {
        ipc.Process(ApplyIpc, e => log.Error(e, "HUD IPC operation failed."));
        PublishStatus();
        bridge.AdoptNativeOpens = config.ReplaceCharacter && client.IsLoggedIn;
        if (toolbar is not null) toolbar.Shown = config.ShowToolbarEntry;
        while (actions.TryDequeue(out var action))
        {
            try { action(); }
            catch (Exception e) { log.Error(e, "XivHud.Character action failed; original character window remains available."); }
        }
        if (!client.IsLoggedIn)
        {
            snapshot = null; unavailable = "Your record will be here when you enter Eorzea.";
            return;
        }
        // Read promptly when the record opens, every 450 ms while it is shown, and
        // occasionally while closed so native adoption has a ready page.
        if (window.IsOpen && !wasOpen) nextRead = 0;
        wasOpen = window.IsOpen;
        if (Environment.TickCount64 < nextRead) return;
        nextRead = Environment.TickCount64 + (window.IsOpen ? 450 : 3000);
        try
        {
            snapshot = data.Read();
            unavailable = snapshot is null ? "Your record is still being prepared. The original character window is still accessible." : null;
        }
        catch (Exception e)
        {
            if (unavailable is null) log.Warning(e, "XivHud.Character could not read the character record.");
            snapshot = null; unavailable = "Your record is unavailable. The original character window is still accessible.";
        }
        }
        finally { PublishStatus(); }
    }

    private void Draw()
    {
        config.NativeWindowEnabled = config.WindowHostEnabled = false;
        if (disposed) return;
        try { window.Draw(snapshot, unavailable, client.IsLoggedIn); }
        catch (Exception e)
        {
            window.Close();
            config.ReplaceCharacter = false;
            bridge.AdoptNativeOpens = false;
            // One handoff only: a failure that repeats every frame must not keep refocusing the native window.
            if (drawFailed) return;
            drawFailed = true;
            bridge.OpenNative();
            log.Error(e, "XivHud.Character drawing failed; restored the original character window and disabled adoption for this session.");
        }
        finally { PublishStatus(); }
    }

    private long nextIpcPublish;
    private void PublishStatus()
    {
        if (disposed || Environment.TickCount64 < nextIpcPublish) return;
        nextIpcPublish = Environment.TickCount64 + 200;
        ipc.Publish(new
    {
        ready = !disposed, loggedIn = client.IsLoggedIn, dataReady = client.IsLoggedIn && snapshot is not null && unavailable is null,
        dataError = unavailable, nativeAdoptionEnabled = config.ReplaceCharacter, nativeBridge = bridge?.BridgeState,
        equippedCount = snapshot?.Gear.Count(g => !g.IsEmpty) ?? 0,
        jobCount = snapshot?.Jobs.Count ?? 0, gearSetCount = snapshot?.GearSets.Count ?? 0,
        window = window?.IpcState,
        commands = new { open = "/xivcharacter open", original = "/xivcharacter native", recovery = "/xivcharacter screen" },
    });
    }

    private string? ApplyIpc(HudCommand command)
    {
        if (command.Method == "character.page")
        {
            window.SelectIpcPage(command.Parameters.GetProperty("page").GetString()!);
            window.Open();
            return null;
        }
        return ApplyWindowCommand(command);
    }

    private string? ApplyWindowCommand(HudCommand command)
    {
        switch (command.Method)
        {
            case "window.layout":
                if (config.NativeWindowEnabled || config.WindowHostEnabled) return "screen_mode_required";
                window.SetScreenLayout(ScreenLayout.Read(command.Parameters)); break;
            case "window.open": window.Open(); break;
            case "window.close": window.Close(); break;
            case "window.settings": window.OpenSettings(); break;
            case "window.original": bridge.OpenNative(); window.Close(); break;
            case "window.mode":
                var mode = command.Parameters.GetProperty("mode").GetString();
                config.NativeWindowEnabled = mode == "native_frame";
                config.WindowHostEnabled = mode == "world";
                if (command.Parameters.TryGetProperty("placement", out var placement)) config.WindowHostPlacement = placement.GetString()!;
                Save(); window.Open(); break;
            default: return "unsupported_method";
        }
        return null;
    }

    public ValueTask DisposeAsync()
    {
        lock (shutdownGate) return new(shutdown ??= ShutdownAsync());
    }

    private async Task ShutdownAsync()
    {
        if (framework.IsInFrameworkUpdateThread) DisposeCore();
        else await framework.RunOnFrameworkThread(DisposeCore).ConfigureAwait(false);
        // Dalamud retains this plugin's services until this task finishes. Native
        // addons close over later frames, so never block the framework while waiting.
        if (window is not null) await window.ShutdownTask.ConfigureAwait(false);
        log.Information("XivHud.Character unloaded; native windows and input ownership released.");
    }

    private void DisposeCore()
    {
        if (disposed) return;
        disposed = true;
        framework.Update -= Update;
        pi.UiBuilder.Draw -= Draw;
        
        
        if (bridge is not null)
        {
            if (window is not null)
            {
                bridge.ToggleRequested -= window.Open;
                bridge.MainCommandToggleRequested -= window.Toggle;
            }
            bridge.Dispose();
        }
        call?.UnregisterFunc(); ipc.Dispose();
        toggle?.UnregisterAction(); settings?.UnregisterAction(); ready?.UnregisterFunc();
        if (commandRegistered) commands.RemoveHandler("/xivcharacter");
        toolbar?.Remove(); toolbar = null;
        window?.Dispose();
    }
}
