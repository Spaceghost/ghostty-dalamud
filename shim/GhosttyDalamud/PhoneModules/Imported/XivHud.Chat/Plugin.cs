using System.Collections.Concurrent;
using Dalamud.Game.Chat;
using Dalamud.Game.ClientState.Conditions;
using Dalamud.Game.Command;
using Dalamud.Game.Gui.Toast;
using Dalamud.Game.Text.SeStringHandling;
using Dalamud.Plugin;
using Dalamud.Plugin.Ipc;
using Dalamud.Plugin.Services;
using XivHud.Chat.Core;
using XivHud.Protocol;
using XivHud.Style;

namespace XivHud.Chat;

internal sealed class Plugin : IDisposable
{
    private readonly IDalamudPluginInterface pi;
    private readonly ICommandManager commands;
    private readonly IFramework framework;
    private readonly IClientState client;
    private readonly IObjectTable objects;
    private readonly IChatGui chat;
    private readonly IToastGui toast;
    private readonly IGameGui game;
    private readonly ICondition condition;
    private readonly IPluginLog log;
    private readonly Configuration config;
    private readonly IllustratedChrome chrome;
    private readonly ChatStore history = new();
    private readonly NotificationStore notices = new();
    private readonly ChatWindow window;
    private readonly ConcurrentQueue<string> ui = new();
    private readonly ConcurrentQueue<SendIntent> outgoing = new();
    private readonly HudEndpoint endpoint = new("chat");
    private ICallGateProvider<string, string>? call;
    private ICallGateProvider<object>? toggle, openSettings;
    private ICallGateProvider<bool>? ready;
    private ulong player;
    private long nextPublish;
    private bool disposed, registered, drawFailed;

    public Plugin(IDalamudPluginInterface pi, ICommandManager commands, IFramework framework, IClientState client,
        IObjectTable objects, IChatGui chat, IToastGui toast, IGameGui game, ICondition condition, IPluginLog log)
    {
        this.pi = pi; this.commands = commands; this.framework = framework; this.client = client;
        this.objects = objects; this.chat = chat; this.toast = toast; this.game = game; this.condition = condition; this.log = log;
        config = GhosttyDalamud.PhoneModules.ModuleConfiguration.Load<Configuration>(pi, "XivHud.Chat");
        config.Enabled = true;
        chrome = new(pi);
        window = new(chrome, config, history, notices, Save, QueueSend);
        try
        {
            registered = commands.AddHandler("/xivchat", new CommandInfo((_, text) => Enqueue(text.Trim().ToLowerInvariant()))
                { HelpMessage = "Conversations and notifications: open, close, settings, preview, off, clear. The original chat UI is suppressed while this plugin is active." });
            if (!registered) throw new InvalidOperationException("/xivchat is already registered");
            call = pi.GetIpcProvider<string, string>("XivHud.Chat.v1.Call"); call.RegisterFunc(endpoint.Call);
            toggle = pi.GetIpcProvider<object>("XivHud.Chat.Toggle"); toggle.RegisterAction(() => Enqueue("toggle"));
            openSettings = pi.GetIpcProvider<object>("XivHud.Chat.OpenSettings"); openSettings.RegisterAction(Settings);
            ready = pi.GetIpcProvider<bool>("XivHud.Chat.Ready"); ready.RegisterFunc(() => !disposed);
            chat.ChatMessageUnhandled += Message;
            toast.Toast += NormalToast; toast.QuestToast += QuestToast; toast.ErrorToast += ErrorToast;
            framework.Update += Update; client.Logout += Logout; pi.UiBuilder.Draw += Draw;
             
        }
        catch { Dispose(); throw; }
    }
    private bool Allowed => client.IsLoggedIn && !game.GameUiHidden && !condition[ConditionFlag.BetweenAreas] && !condition[ConditionFlag.BetweenAreas51]
        && !condition[ConditionFlag.WatchingCutscene] && !condition[ConditionFlag.WatchingCutscene78] && !condition[ConditionFlag.OccupiedInCutSceneEvent];
    private void Save() => GhosttyDalamud.PhoneModules.ModuleConfiguration.Save(pi, "XivHud.Chat", config);
    private void Open() => Enqueue("open");
    private void Settings() => Enqueue("settings");
    private void Enqueue(string value) { if (!disposed && ui.Count < 32) ui.Enqueue(value); }
    private void Logout(int a, int b) { history.Clear(); notices.Clear(); outgoing.Clear(); player = 0; window.Draft = window.Recipient = ""; window.Sending = false; window.SentDraft = null; window.Status = ""; }
    private void Apply(string value)
    {
        switch (value)
        {
            case "toggle": Apply(window.Open ? "close" : "open"); break;
            case "open": config.Enabled = true; window.Open = true; window.Preview = false; drawFailed = false; Save(); break;
            case "close": window.Open = window.Preview = false; break;
            case "off": config.Enabled = false; window.Open = window.Preview = false; outgoing.Clear(); window.Sending = false; history.Clear(); notices.Clear(); Save(); break;
            case "clear": history.Clear(); notices.Clear(); break;
            case "preview": window.Preview = !window.Preview; window.Open = window.SettingsOpen = true; drawFailed = false; break;
            default: window.SettingsOpen = true; break;
        }
    }
    private void Message(IChatMessage message)
    {
        if (disposed || !config.Enabled || !client.IsLoggedIn) return;
        try
        {
            var type = message.LogKind.ToString();
            if (ChatStore.IsCombatLog(type)) return;
            var timestamp = message.Timestamp > 0 ? DateTimeOffset.FromUnixTimeSeconds(message.Timestamp) : DateTimeOffset.UtcNow;
            var incoming = type is "TellIncoming" or "GmTell";
            var entry = history.Append(timestamp, ChatStore.Classify(type), message.Sender.TextValue, message.Message.TextValue, incoming);
            if (entry is not null && incoming && config.NotifyTells && config.Notifications)
                notices.Push("Chat", "Tell from " + entry.Sender, entry.Text, NotificationKind.Message, Environment.TickCount64, ChatChannel.Tell);
        }
        catch (Exception) { } // Event objects are copied only during their valid callback lifetime.
    }
    private void NormalToast(ref SeString message, ref ToastOptions options, ref bool handled)
    { if (!disposed && config.Enabled && config.Notifications && config.NotifyNormal && !handled) notices.Push("Game", "Notice", message.TextValue, NotificationKind.Info, Environment.TickCount64); }
    private void QuestToast(ref SeString message, ref QuestToastOptions options, ref bool handled)
    { if (!disposed && config.Enabled && config.Notifications && config.NotifyQuests && !handled) notices.Push("Quests", "Quest update", message.TextValue, NotificationKind.Quest, Environment.TickCount64); }
    private void ErrorToast(ref SeString message, ref bool handled)
    { if (!disposed && config.Enabled && config.Notifications && config.NotifyErrors && !handled) notices.Push("Game", "Game error", message.TextValue, NotificationKind.Error, Environment.TickCount64); }
    private void QueueSend(ChatChannel channel, string text, string recipient)
    {
        if (disposed || window.Sending || window.Preview) return;
        var line = ChatComposer.Build(channel, text, recipient, out var error);
        if (line is null) { window.Status = error ?? "Message unavailable"; return; }
        if (!config.Enabled || !Allowed || player == 0 || !NativeChatInput.Supported) { window.Status = "Game chat is not ready"; return; }
        window.Sending = true; outgoing.Enqueue(new(player, line, Environment.TickCount64, text));
    }
    private void Update(IFramework _)
    {
        if (disposed) return;
        endpoint.Process(c =>
        {
            if (c.Method == "window.layout") { window.SetScreenLayout(ScreenLayout.Read(c.Parameters)); return null; }
            if (c.Method == "notification.push")
            {
                if (!config.Enabled || !config.Notifications) return "notifications_disabled";
                var p = c.Parameters;
                notices.Push("Mod", p.GetProperty("title").GetString()!, p.GetProperty("text").GetString()!,
                    Enum.Parse<NotificationKind>(p.GetProperty("kind").GetString()!), Environment.TickCount64);
            }
            else Apply(c.Method switch { "window.open" => "open", "window.close" => "close", _ => "settings" });
            return null;
        }, e => log.Warning(e, "Chat UI request failed"));
        for (var i = 0; i < 8 && ui.TryDequeue(out var value); i++) Apply(value);
        player = client.IsLoggedIn && objects.LocalPlayer is { } local ? local.GameObjectId : 0;
        if (outgoing.TryDequeue(out var intent))
        {
            try
            {
                if (ChatComposer.CanSubmit(intent, player, Environment.TickCount64, config.Enabled, Allowed, window.Preview) && NativeChatInput.Supported)
                { NativeChatInput.Send(intent.Line); window.SentDraft = intent.Draft; window.Status = "Submitted to game chat"; }
                else window.Status = "Send expired or character changed; confirm again";
            }
            catch (Exception e) { window.Status = e is InvalidOperationException ? e.Message : "Chat input unavailable · native chat remains available"; }
            finally { window.Sending = false; }
        }
        if (Environment.TickCount64 >= nextPublish)
        {
            nextPublish = Environment.TickCount64 + 200;
            endpoint.Publish(new { ready = !drawFailed, loggedIn = client.IsLoggedIn, enabled = config.Enabled,
                unread = history.Unread(ChatChannel.All), messages = history.Snapshot().Count, notifications = notices.Active(Environment.TickCount64, NotificationStore.Capacity).Count,
                settingsOpen = window.SettingsOpen, preview = window.Preview,
                window = new { layout = window.Layout, open = window.Open, actualMode = "screen", requestedMode = "screen" }, recoveryCommand = "/xivchat off" });
        }
    }
    private void Draw()
    {
        if (disposed || drawFailed) return;
        try { window.Draw(!game.GameUiHidden, Allowed && player != 0 && NativeChatInput.Supported && !window.Sending); }
        catch (Exception e) { drawFailed = true; window.Open = window.SettingsOpen = false; log.Error(e, "Chat drawing stopped; original chat remains suppressed"); }
    }
    public void Dispose()
    {
        if (disposed) return; disposed = true;
        chat.ChatMessageUnhandled -= Message;
        toast.Toast -= NormalToast; toast.QuestToast -= QuestToast; toast.ErrorToast -= ErrorToast;
        framework.Update -= Update; client.Logout -= Logout; pi.UiBuilder.Draw -= Draw;
         
        toggle?.UnregisterAction(); openSettings?.UnregisterAction(); ready?.UnregisterFunc();
        chrome.Dispose(); call?.UnregisterFunc(); endpoint.Dispose(); if (registered) commands.RemoveHandler("/xivchat");
        history.Clear(); notices.Clear(); outgoing.Clear(); ui.Clear();
    }
}
