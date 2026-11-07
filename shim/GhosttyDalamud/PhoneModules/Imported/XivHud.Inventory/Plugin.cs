using Dalamud.Game.ClientState.Conditions;
using Dalamud.Game.Command;
using Dalamud.Plugin;
using Dalamud.Plugin.Ipc;
using Dalamud.Plugin.Services;
using System.Collections.Concurrent;
using XivHud.Items.Core;
using XivHud.Items.Dalamud;
using XivHud.Protocol;
namespace XivHud.Inventory;

internal sealed class Plugin : IDisposable
{
    private readonly IDalamudPluginInterface pi;
    private readonly ICommandManager commands;
    private readonly IFramework framework;
    private readonly IClientState client;
    private readonly ICondition conditions;
    private readonly IGameGui game;
    private readonly IPluginLog log;
    private readonly ItemData data;
    private readonly ModuleWindow window;
    private readonly HudEndpoint endpoint = new("inventory");
    private readonly ConcurrentQueue<string> requests = new();
    private ICallGateProvider<string, string>? call;
    private ICallGateProvider<object>? toggle, settings;
    private ICallGateProvider<bool>? ready;
    private bool disposed, registered, failed;
    private long nextRead, nextPublish;
    private uint territory;
    public Plugin(IDalamudPluginInterface pi, ICommandManager commands, IFramework framework, IClientState client,
        ICondition conditions, IGameGui game, IDataManager sheets, ITextureProvider textures, IPluginLog log)
    {
        this.pi = pi; this.commands = commands; this.framework = framework; this.client = client;
        this.conditions = conditions; this.game = game; this.log = log;
        data = new(sheets); window = new(textures);
        try
        {
            registered = commands.AddHandler("/xivinventory", new CommandInfo((_, args) => Queue(args.Trim().ToLowerInvariant())) { HelpMessage = "Open Inventory; close, preview, settings." });
            if (!registered) throw new InvalidOperationException("/xivinventory already registered");
            call = pi.GetIpcProvider<string, string>("XivHud.Inventory.v1.Call"); call.RegisterFunc(endpoint.Call);
            toggle = pi.GetIpcProvider<object>("XivHud.Inventory.Toggle"); toggle.RegisterAction(() => Queue("toggle"));
            settings = pi.GetIpcProvider<object>("XivHud.Inventory.OpenSettings"); settings.RegisterAction(Open);
            ready = pi.GetIpcProvider<bool>("XivHud.Inventory.Ready"); ready.RegisterFunc(() => !disposed);
            framework.Update += Update; client.Logout += Logout;
            pi.UiBuilder.Draw += Draw;  
        } catch { Dispose(); throw; }
    }
    private bool Allowed => client.IsLoggedIn && !game.GameUiHidden && !conditions[ConditionFlag.BetweenAreas] && !conditions[ConditionFlag.BetweenAreas51]
        && !conditions[ConditionFlag.WatchingCutscene] && !conditions[ConditionFlag.WatchingCutscene78] && !conditions[ConditionFlag.OccupiedInCutSceneEvent]
        && !conditions[ConditionFlag.OccupiedInQuestEvent];
    private void Queue(string value) { if (!disposed && requests.Count < 32) requests.Enqueue(value); }
    private void Open() => Queue("open");
    private void Apply(string value)
    {
        if (value == "toggle") value = window.Open ? "close" : "open";
        if (value == "close") { window.Open = false; window.Preview = false; window.Bags = BagSnapshot.Empty; return; }
        window.Open = true; window.Preview = value == "preview"; failed = false; nextRead = 0;
    }
    private void Logout(int a, int b) { window.Clear(); requests.Clear(); }
    private void Update(IFramework _)
    {
        if (disposed) return;
        endpoint.Process(c => { Apply(c.Method == "window.close" ? "close" : "open"); return null; }, e => log.Warning(e, "Inventory request failed"));
        for (var i = 0; i < 8 && requests.TryDequeue(out var value); i++) Apply(value);
        if (!Allowed || territory != client.TerritoryType) window.Bags = BagSnapshot.Empty;
        territory = client.TerritoryType;
        if (window.Open && !failed && Environment.TickCount64 >= nextRead)
        {
            nextRead = Environment.TickCount64 + 1000;
            try
            {
                if (Allowed && !window.Preview) window.Bags = data.Read();

            }
            catch (Exception e) { window.Bags = BagSnapshot.Empty; failed = true; log.Warning(e, "Inventory data unavailable"); }
        }
        if (Environment.TickCount64 < nextPublish) return;
        nextPublish = Environment.TickCount64 + 200;
        endpoint.Publish(new { ready = !failed, loggedIn = client.IsLoggedIn, bindingsSupported = ItemData.Supported,
            loadedBags = window.Bags.LoadedBags, preview = window.Preview,
            window = new { open = window.Open, actualMode = "screen", requestedMode = "screen" }, recoveryCommand = "/xivinventory close" });
    }
    private void Draw()
    {
        if (disposed || !window.Open || !Allowed && !window.Preview) return;
        try { window.Draw(failed ? "Game data unavailable; close and reopen to retry." : !ItemData.Supported ? "Unreviewed inventory bindings; live bag counts unavailable." : ""); }
        catch (Exception e) { window.Open = false; log.Error(e, "Inventory drawing stopped"); }
    }
    public void Dispose()
    {
        if (disposed) return; disposed = true;
        framework.Update -= Update; client.Logout -= Logout;
        pi.UiBuilder.Draw -= Draw;  
        toggle?.UnregisterAction(); settings?.UnregisterAction(); ready?.UnregisterFunc(); call?.UnregisterFunc(); endpoint.Dispose(); if (registered) commands.RemoveHandler("/xivinventory");
        window.Clear(); requests.Clear();
    }
}
