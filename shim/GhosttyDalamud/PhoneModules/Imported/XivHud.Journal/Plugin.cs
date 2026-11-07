using System.Collections.Concurrent;
using Dalamud.Game.ClientState.Conditions;
using XivHud.Protocol;
using Dalamud.Game.Command;
using Dalamud.Game.Gui.Dtr;
using Dalamud.Plugin;
using Dalamud.Plugin.Ipc;
using Dalamud.Plugin.Services;

namespace XivHud.Journal;

internal sealed class Plugin
{
    private readonly IDalamudPluginInterface pi;
    private readonly ICommandManager commands;
    private readonly IFramework framework;
    private readonly IClientState client;
    private readonly ICondition condition;
    private readonly IGameGui gameGui;
    private readonly IPluginLog log;
    private readonly Configuration config;
    private readonly JournalData data = null!;
    private readonly NativeJournalBridge bridge = null!;
    private readonly JournalWindow window = null!;
    private readonly JournalTracker tracker = null!;
    private readonly ConcurrentQueue<Action> actions = new();
    private readonly ICallGateProvider<object> toggle = null!, settings = null!;
    private readonly ICallGateProvider<bool> ready = null!;
    private readonly HudEndpoint ipc = new("journal");
    private ICallGateProvider<string, string>? call;
    private IDtrBarEntry? toolbar;
    private IReadOnlyList<JournalEntry> entries = [];
    private string? unavailable = "Your journal will be here when you enter Eorzea.";
    private long nextRead;
    private long lastRead;
    private bool disposed, commandRegistered;
    private readonly object shutdownGate = new();
    private Task? shutdown;

    public Plugin(IDalamudPluginInterface pi, ICommandManager commands, IFramework framework,
        IClientState client, IDataManager dataManager, IAddonLifecycle lifecycle, IDtrBar dtr, IPluginLog log, ITextureProvider textures, IGameInteropProvider interop,
        ICondition condition, IGameGui gameGui)
    {
        this.pi = pi; this.commands = commands; this.framework = framework; this.client = client; this.log = log;
        this.condition = condition; this.gameGui = gameGui;
        config = GhosttyDalamud.PhoneModules.ModuleConfiguration.Load<Configuration>(pi, "XivHud.Journal");
        config.Scale = float.IsFinite(config.Scale) ? Math.Clamp(config.Scale, .8f, 1.5f) : 1;
        config.Bookmarks ??= [];
        config.TrackerLimit = Math.Clamp(config.TrackerLimit, 1, 5);
        config.TrackerAnchor = JournalTrackerPolicy.Anchor(config.TrackerAnchor);
        config.NativeWindowEnabled = config.WindowHostEnabled = config.ShowToolbarEntry = false;
        try
        {
            data = new(dataManager);
            bridge = new(lifecycle, framework, log, interop);
            window = new(pi, config, Save, QueueNativeQuest, QueueNativeJournal,
                id => actions.Enqueue(() => { bridge.ShowOnMap(id); window.Close(); }), textures);
            tracker = new(pi, config, Save, id => actions.Enqueue(() => window.Open(id)));
            toggle = pi.GetIpcProvider<object>("XivHud.Journal.Toggle");
            settings = pi.GetIpcProvider<object>("XivHud.Journal.OpenSettings");
            ready = pi.GetIpcProvider<bool>("XivHud.Journal.Ready");
            toggle.RegisterAction(() => actions.Enqueue(window.Toggle));
            settings.RegisterAction(() => actions.Enqueue(window.OpenSettings));
            ready.RegisterFunc(() => !disposed);
            call = pi.GetIpcProvider<string, string>("XivHud.Journal.v1.Call");
            call.RegisterFunc(ipc.Call);
            PublishStatus();
            commandRegistered = commands.AddHandler("/xivjournal", new CommandInfo(OnCommand)
                { HelpMessage = "Open XivHud Journal. Options: open, close, settings, screen, frame, world, native, tracker [on/off/lock/unlock/tracked/bookmarks], status." });
            if (!commandRegistered) throw new InvalidOperationException("/xivjournal is already registered.");
            bridge.ToggleRequested += OpenNativeSelection;
            bridge.MainCommandToggleRequested += window.Toggle;
            bridge.CanAdoptQuest = id => unavailable is null && (id == 0 || entries.Any(q => q.Id == id));
            bridge.AdoptNativeOpens = config.ReplaceJournal;
            toolbar = dtr.Get("XivHud.Journal");
            toolbar.Text = "Journal";
            toolbar.Tooltip = "Adventurer's Journal\nClick to open. Right-click to change its appearance.";
            toolbar.OnClick = e => actions.Enqueue(e.ClickType == MouseClickType.Right ? window.OpenSettings : window.Toggle);
            toolbar.Shown = config.ShowToolbarEntry;
            framework.Update += Update;
            pi.UiBuilder.Draw += Draw;
            
            
            log.Information("XivHud.Journal ready. /xivjournal opens the adventurer's journal. Native fallback remains available.");
        }
        catch { DisposeCore(); throw; }
    }

    public Task LoadAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        return Task.CompletedTask;
    }

    private void Save() => GhosttyDalamud.PhoneModules.ModuleConfiguration.Save(pi, "XivHud.Journal", config);
    private void QueueNativeQuest(uint id) => actions.Enqueue(() => { bridge.OpenNativeQuest(id); window.Close(); });
    private void QueueNativeJournal() => actions.Enqueue(() => { bridge.OpenNative(); window.Close(); });
    private void OpenNativeSelection() => window.Open(bridge.SelectedQuestId);
    private void Open() => actions.Enqueue(() => window.Open());
    private void Settings() => actions.Enqueue(window.OpenSettings);
    private void OnCommand(string command, string args)
    {
        switch (args.Trim().ToLowerInvariant())
        {
            case "open": Open(); break;
            case "close": actions.Enqueue(window.Close); break;
            case "settings": Settings(); break;
            case "tracker": case "tracker on": actions.Enqueue(() => { config.TrackerEnabled = true; Save(); }); break;
            case "tracker off": actions.Enqueue(() => { config.TrackerEnabled = false; Save(); }); break;
            case "tracker lock": actions.Enqueue(() => { config.TrackerLocked = true; Save(); }); break;
            case "tracker unlock": actions.Enqueue(() => { config.TrackerLocked = false; Save(); }); break;
            case "tracker tracked": actions.Enqueue(() => { config.TrackerBookmarks = false; config.TrackerEnabled = true; Save(); }); break;
            case "tracker bookmarks": actions.Enqueue(() => { config.TrackerBookmarks = true; config.TrackerEnabled = true; Save(); }); break;
            case "screen": actions.Enqueue(() => { config.WindowHostEnabled = false; config.NativeWindowEnabled = false; Save(); window.Open(); }); break;
            case "frame": actions.Enqueue(() => { config.WindowHostEnabled = false; config.NativeWindowEnabled = true; Save(); window.Open(); }); break;
            case "world": actions.Enqueue(() => { config.NativeWindowEnabled = false; config.WindowHostEnabled = true; config.WindowHostPlacement = "Hud"; Save(); window.Open(); }); break;
            case "native": actions.Enqueue(() => { bridge.OpenNative(); window.Close(); }); break;
            case "game": actions.Enqueue(bridge.InvokeGameJournal); break;
            case "status": actions.Enqueue(() => log.Information("XivHud.Journal status: open={Open}; quests={Quests}; nativeAdoption={Adopt}; data={Status}; bridge={Bridge}; controller={Controller}; window={Window}", window.IsOpen, entries.Count, config.ReplaceJournal, unavailable ?? "ready", bridge.BridgeState, window.ControllerStatus, window.HostingStatus)); break;
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
        bridge.AdoptNativeOpens = config.ReplaceJournal && client.IsLoggedIn;
        if (toolbar is not null) toolbar.Shown = config.ShowToolbarEntry;
        while (actions.TryDequeue(out var action))
        {
            try { action(); }
            catch (Exception e) { log.Error(e, "XivHud.Journal action failed; original journal remains available."); }
        }
        if (!client.IsLoggedIn)
        {
            entries = []; unavailable = "Your journal will be here when you enter Eorzea.";
            return;
        }
        if (Environment.TickCount64 < nextRead) return;
        nextRead = Environment.TickCount64 + 400;
        try { entries = data.Read(); unavailable = null; lastRead = Environment.TickCount64; }
        catch (Exception e)
        {
            if (unavailable is null) log.Warning(e, "XivHud.Journal could not read the current quest journal.");
            entries = []; unavailable = "Your quest pages are unavailable. The original journal is still accessible.";
        }
        }
        finally { PublishStatus(); }
    }

    private void Draw()
    {
        config.NativeWindowEnabled = config.WindowHostEnabled = false;
        if (disposed) return;
        try { window.Draw(entries, unavailable, client.IsLoggedIn); }
        catch (Exception e)
        {
            window.Close();
            config.ReplaceJournal = false;
            bridge.AdoptNativeOpens = false;
            bridge.OpenNative();
            log.Error(e, "XivHud.Journal drawing failed; restored original Journal and disabled adoption for this session.");
        }
        finally
        {
            try { tracker.Draw(entries, client.IsLoggedIn && !gameGui.GameUiHidden
                && !condition[ConditionFlag.BetweenAreas] && !condition[ConditionFlag.BetweenAreas51]
                && !condition[ConditionFlag.WatchingCutscene] && !condition[ConditionFlag.WatchingCutscene78]
                && !condition[ConditionFlag.OccupiedInCutSceneEvent]
                && !condition[ConditionFlag.OccupiedInEvent] && !condition[ConditionFlag.OccupiedInQuestEvent]
                && unavailable is null && Environment.TickCount64 - lastRead <= 2000); }
            catch (Exception e) { config.TrackerEnabled = false; log.Error(e, "Journal tracker drawing stopped for this session; the quest book remains available."); }
            PublishStatus();
        }
    }

    private long nextIpcPublish;
    private void PublishStatus()
    {
        if (disposed || Environment.TickCount64 < nextIpcPublish) return;
        nextIpcPublish = Environment.TickCount64 + 200;
        ipc.Publish(new
    {
        ready = !disposed, loggedIn = client.IsLoggedIn, dataReady = client.IsLoggedIn && unavailable is null,
        dataError = unavailable, nativeAdoptionEnabled = config.ReplaceJournal, nativeBridge = bridge?.BridgeState,
        acceptedQuestCount = entries.Count, bookmarks = config.Bookmarks.Order().ToArray(),
        window = window?.IpcState,
        tracker = tracker?.IpcState,
        commands = new { open = "/xivjournal open", original = "/xivjournal native", recovery = "/xivjournal screen" },
    });
    }

    private string? ApplyIpc(HudCommand command)
    {
        var p = command.Parameters;
        if (command.Method == "journal.tracker")
        {
            config.TrackerEnabled = p.GetProperty("enabled").GetBoolean();
            if (p.TryGetProperty("locked", out var locked)) config.TrackerLocked = locked.GetBoolean();
            if (p.TryGetProperty("filter", out var filter)) config.TrackerBookmarks = filter.GetString() == "bookmarks";
            if (p.TryGetProperty("limit", out var limit)) config.TrackerLimit = limit.GetInt32();
            Save(); return null;
        }
        if (command.Method.StartsWith("journal.", StringComparison.Ordinal))
        {
            if (!client.IsLoggedIn || unavailable is not null) return "journal_data_unavailable";
            var id = p.GetProperty("questId").GetUInt32();
            if (!entries.Any(q => q.Id == id)) return "quest_not_in_accepted_journal";
            switch (command.Method)
            {
                case "journal.select": window.Open(id); break;
                case "journal.bookmark":
                    if (p.GetProperty("bookmarked").GetBoolean()) config.Bookmarks.Add(id); else config.Bookmarks.Remove(id);
                    Save(); break;
                case "journal.show_map": bridge.ShowOnMap(id); window.Close(); break;
            }
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
        log.Information("XivHud.Journal unloaded; native windows and input ownership released.");
    }

    private void DisposeCore()
    {
        if (disposed) return;
        disposed = true;
        framework.Update -= Update;
        pi.UiBuilder.Draw -= Draw;
        
        
        if (bridge is not null)
        {
            bridge.ToggleRequested -= OpenNativeSelection;
            if (window is not null) bridge.MainCommandToggleRequested -= window.Toggle;
            bridge.Dispose();
        }
        call?.UnregisterFunc(); ipc.Dispose();
        toggle?.UnregisterAction(); settings?.UnregisterAction(); ready?.UnregisterFunc();
        if (commandRegistered) commands.RemoveHandler("/xivjournal");
        toolbar?.Remove(); toolbar = null;
        window?.Dispose();
        tracker?.Dispose();
    }
}
