using System.Numerics;
using XivHud.Protocol;
using XivHud.Style;
using Dalamud.Bindings.ImGui;
using XivHud.Chat.Core;
using static XivHud.Style.IllustratedStyle;

namespace XivHud.Chat;

internal sealed class ChatWindow(IllustratedChrome chrome, Configuration config, ChatStore history, NotificationStore notices, Action save, Action<ChatChannel, string, string> send)
{
    private readonly WorkspaceLayout workspace = new();
    internal ScreenLayout? Layout => workspace.Current;
    internal void SetScreenLayout(ScreenLayout rect) => workspace.Queue(rect);
    internal bool Open, SettingsOpen, Preview;
    internal volatile bool Sending;
    internal volatile string? SentDraft;
    internal string Status = "", Draft = "", Recipient = "";
    private string search = "";
    private ChatChannel channel = ChatChannel.All, compose = ChatChannel.Say;
    private long seenRevision = -1;
    private bool follow = true, showNotifications;
    private IReadOnlyList<ChatEntry> cached = [];
    private string cachedSearch = "";
    private ChatChannel cachedChannel;

    internal void Draw(bool allowed, bool canSend)
    {
        if (!allowed && !Preview) return;
        IllustratedChrome.BeginTheme();
        try
        {
            using var body = chrome.Body();
            if (Open) Conversation(canSend);
            // Notices stay in the phone notification center; no flat HUD cards.
            if (SettingsOpen) Settings();
        }
        finally { IllustratedChrome.EndTheme(); }
    }
    private void Conversation(bool canSend)
    {
        if (SentDraft is { } sent) { if (Draft == sent) Draft = ""; SentDraft = null; }
        var viewport = ImGui.GetMainViewport();
        var available = Vector2.Max(new Vector2(1), viewport.WorkSize - new Vector2(24));
        ImGui.SetNextWindowSize(Vector2.Min(new(960, 660), available), ImGuiCond.FirstUseEver);
        ImGui.SetNextWindowPos(viewport.WorkPos + viewport.WorkSize * .5f, ImGuiCond.FirstUseEver, new(.5f));
        ImGui.SetNextWindowSizeConstraints(Vector2.Min(new(680, 480), available), available);
        var shown = Open;
        var flags = ImGuiWindowFlags.NoTitleBar | ImGuiWindowFlags.NoBackground | ImGuiWindowFlags.NoMove | ImGuiWindowFlags.NoScrollbar | ImGuiWindowFlags.NoScrollWithMouse;
        workspace.ApplyNext();
        var drew = ImGui.Begin("Adventurer's Correspondence###XivHud.Chat", ref shown, flags);
        try
        {
            if (!drew) return;
            workspace.Observe();
            var p = ImGui.GetWindowPos(); var size = ImGui.GetWindowSize(); var d = ImGui.GetWindowDrawList();
            Frame(d, p, size, 1, config.Ornament);
            chrome.Title(p + new Vector2(12, 9), "Correspondence", "Conversations, letters and small tidings.", Preview);
            ImGui.SetCursorScreenPos(p + new Vector2(18, 12));
            ImGui.InvisibleButton("##binding-drag", new(size.X - 260, 78));
            if (ImGui.IsItemActive() && ImGui.IsMouseDragging(ImGuiMouseButton.Left)) ImGui.SetWindowPos(p + ImGui.GetIO().MouseDelta);
            ImGui.SetCursorScreenPos(p + new Vector2(size.X - 228, 35));
            if (ImGui.Button("Appearance")) SettingsOpen = true;
            ImGui.SameLine(); if (ImGui.Button("Close")) shown = false;
            Rule(d, p + new Vector2(24, 104), size.X - 48, Gold, 1);
            ImGui.SetCursorScreenPos(p + new Vector2(24, 123));
            if (ImGui.BeginChild("##chapters", new Vector2(166, size.Y - 165), false))
            {
                ImGui.TextColored(V(PaleGold), "CONVERSATIONS"); ImGui.Spacing();
                foreach (var item in Enum.GetValues<ChatChannel>())
                {
                    var unread = Preview ? 0 : history.Unread(item);
                    if (ImGui.Selectable(ChannelLabel(item) + (unread > 0 ? $"  ({unread})" : ""), !showNotifications && channel == item))
                    { channel = item; showNotifications = false; follow = true; }
                }
                ImGui.Spacing(); ImGui.Separator(); ImGui.Spacing();
                if (ImGui.Selectable("Notification center", showNotifications)) showNotifications = true;
                ImGui.Spacing(); ImGui.TextColored(V(Muted), Preview ? "SAMPLE PAGES" : "THIS SESSION");
            }
            ImGui.EndChild();
            var paper = p + new Vector2(210, 122); var paperSize = size - new Vector2(234, 168);
            Paper(d, paper, paperSize, 1, config.DarkPaper, config.Ornament);
            ImGui.SetCursorScreenPos(paper + new Vector2(18, 18));
            if (ImGui.BeginChild("##correspondence-page", paperSize - new Vector2(36), false))
            {
                if (showNotifications) NotificationInbox();
                else ConversationPage(canSend);
            }
            ImGui.EndChild();
            ImGui.SetCursorScreenPos(p + new Vector2(28, size.Y - 30));
            ImGui.TextColored(V(Muted), "Session correspondence  ·  Native chat and rich links remain within reach");
        }
        finally { ImGui.End(); Open = shown; }
    }
    private void ConversationPage(bool canSend)
    {
        var ink = config.DarkPaper ? Ivory : Ink;
        ImGui.PushStyleColor(ImGuiCol.Text, V(ink));
        ImGui.PushStyleColor(ImGuiCol.TextDisabled, V(config.DarkPaper ? Muted : C(100, 88, 66)));
        ImGui.PushStyleColor(ImGuiCol.FrameBg, V(config.DarkPaper ? Ink : C(214, 199, 163)));
        ImGui.PushStyleColor(ImGuiCol.Button, V(config.DarkPaper ? Leather : C(214, 199, 163)));
        try
        {
            ImGui.TextUnformatted(ChannelLabel(channel));
            ImGui.SameLine(); ImGui.BeginDisabled(Preview);
            if (ImGui.SmallButton("Mark read")) history.MarkRead(channel, history.Snapshot(channel).LastOrDefault()?.Id ?? 0);
            ImGui.EndDisabled();
            ImGui.SetNextItemWidth(-1); ImGui.InputTextWithHint("##search", "Search this conversation…", ref search, 160);
            if (seenRevision != history.Revision || cachedChannel != channel || cachedSearch != search)
            { cached = history.Snapshot(channel, search); cachedChannel = channel; cachedSearch = search; seenRevision = history.Revision; }
            IReadOnlyList<ChatEntry> rows = Preview ? Samples() : cached;
            if (ImGui.BeginChild("##messages", new Vector2(0, -145), false))
            {
                // Respect wheel and scrollbar movement before requesting any follow scroll.
                if (ImGui.IsWindowHovered() && (ImGui.GetIO().MouseWheel != 0 || ImGui.IsMouseDown(ImGuiMouseButton.Left)))
                    follow = ImGui.GetScrollY() >= ImGui.GetScrollMaxY() - 8;
                ImGui.PushTextWrapPos(0);
                foreach (var item in rows)
                {
                    ImGui.PushID(item.Id.ToString());
                    ImGui.TextColored(config.DarkPaper ? ChannelColour(item.Channel) : V(C(103, 77, 37)), $"{item.Timestamp.ToLocalTime():HH:mm}  [{ChannelLabel(item.Channel)}] {item.Sender}");
                    ImGui.TextWrapped(item.Text);
                    if (ImGui.BeginPopupContextItem("##message-menu"))
                    {
                        if (ImGui.MenuItem("Copy message")) ImGui.SetClipboardText(item.Text);
                        ImGui.EndPopup();
                    }
                    ImGui.Spacing(); ImGui.PopID();
                }
                ImGui.PopTextWrapPos();
                if (rows.Count == 0) ImGui.TextDisabled("No messages in this conversation yet.");
                if (follow && search.Length == 0) ImGui.SetScrollHereY(1);
                follow = ImGui.GetScrollY() >= ImGui.GetScrollMaxY() - 8;
                if (follow && search.Length == 0 && ImGui.IsWindowFocused(ImGuiFocusedFlags.RootAndChildWindows) && !Preview)
                    history.MarkRead(channel, rows.LastOrDefault()?.Id ?? 0);
            }
            ImGui.EndChild();
            ImGui.Separator();
            // The composer stays on the dark binding so controls and drafts retain contrast.
            ImGui.PushStyleColor(ImGuiCol.Text, V(Ivory));
            ImGui.PushStyleColor(ImGuiCol.TextDisabled, V(Muted));
            ImGui.PushStyleColor(ImGuiCol.FrameBg, V(Ink));
            ImGui.PushStyleColor(ImGuiCol.Button, V(Leather));
            try
            {
            ImGui.SetNextItemWidth(160);
            if (ImGui.BeginCombo("##compose-channel", ChannelLabel(compose)))
            {
                foreach (var item in new[] { ChatChannel.Say, ChatChannel.Party, ChatChannel.Alliance, ChatChannel.FreeCompany, ChatChannel.Tell })
                    if (ImGui.Selectable(ChannelLabel(item), item == compose)) compose = item;
                ImGui.EndCombo();
            }
            if (compose == ChatChannel.Tell)
            { ImGui.SameLine(); ImGui.SetNextItemWidth(-1); var recipient = Preview ? "Sample Friend@World" : Recipient; ImGui.InputTextWithHint("##recipient", "Firstname Lastname@World", ref recipient, 100); if (!Preview) Recipient = recipient; }
            ImGui.BeginDisabled(!canSend || Preview || !config.Enabled);
            ImGui.SetNextItemWidth(-80);
            var draft = Preview ? "" : Draft;
            var enter = ImGui.InputTextWithHint("##draft", Preview ? "Sending is disabled in sample preview" : "Write a message…", ref draft, 2000, ImGuiInputTextFlags.EnterReturnsTrue);
            if (!Preview) Draft = draft;
            ImGui.SameLine(); var clicked = ImGui.Button("Send", new(70, 0));
            if ((enter || clicked) && !Preview && canSend && config.Enabled) send(compose, Draft, Recipient);
            ImGui.EndDisabled();
            }
            finally { ImGui.PopStyleColor(4); }
            if (Status.Length > 0) ImGui.TextWrapped(Status);
        }
        finally { ImGui.PopStyleColor(4); }
    }
    private void NotificationInbox()
    {
        ImGui.PushStyleColor(ImGuiCol.Text, V(config.DarkPaper ? Ivory : Ink));
        ImGui.PushStyleColor(ImGuiCol.Button, V(config.DarkPaper ? Leather : C(214, 199, 163)));
        ImGui.PushStyleColor(ImGuiCol.TextDisabled, V(config.DarkPaper ? Muted : C(100, 88, 66)));
        try
        {
        ImGui.TextUnformatted("Notification center");
        ImGui.BeginDisabled(Preview); if (ImGui.Button("Clear notifications")) notices.Clear(); ImGui.EndDisabled();
        if (ImGui.BeginChild("##notice-history", new Vector2(0, 0), false))
        {
            var items = Preview ? new Notice[] { new(-1, "SAMPLE", "Quest update", "A sample notification stays in the center after its card expires.", NotificationKind.Quest, Environment.TickCount64) } : notices.History();
            foreach (var item in items)
            {
                ImGui.PushID(item.Id.ToString());
                ImGui.TextColored(config.DarkPaper ? V(PaleGold) : V(C(103, 77, 37)), item.Title);
                ImGui.TextDisabled(item.Source + (item.Count > 1 ? " ×" + item.Count : "")); ImGui.TextWrapped(item.Text);
                if (item.Channel is { } target && ImGui.Button("Open conversation")) { channel = target; showNotifications = false; follow = true; }
                ImGui.Separator(); ImGui.PopID();
            }
            if (items.Count == 0) ImGui.TextDisabled("No notifications in this session");
        }
        ImGui.EndChild();
        }
        finally { ImGui.PopStyleColor(3); }
    }

    private void Notifications()
    {
        var viewport = ImGui.GetMainViewport(); var offset = 0f;
        foreach (var notice in Preview ? new Notice[] { new(-1, "SAMPLE", "A sample tell", "Click a notification to return to its conversation.", NotificationKind.Message, 0, Channel: ChatChannel.Tell) } : notices.Active(Environment.TickCount64))
        {
            ImGui.SetNextWindowPos(viewport.WorkPos + new Vector2(viewport.WorkSize.X - 370, 70 + offset));
            ImGui.SetNextWindowSize(new(350, 0));
            var shown = true;
            var flags = ImGuiWindowFlags.NoTitleBar | ImGuiWindowFlags.NoBackground | ImGuiWindowFlags.NoSavedSettings | ImGuiWindowFlags.NoMove | ImGuiWindowFlags.NoResize | ImGuiWindowFlags.NoFocusOnAppearing | ImGuiWindowFlags.NoNav | ImGuiWindowFlags.AlwaysAutoResize;
            var drew = ImGui.Begin(notice.Title.Replace("##", "＃＃", StringComparison.Ordinal) + "###XivHud.Chat.Notice." + notice.Id, ref shown, flags);
            try
            {
                if (drew)
                {
                    var card = ImGui.GetWindowPos(); var cardSize = ImGui.GetWindowSize();
                    Frame(ImGui.GetWindowDrawList(), card, cardSize, 1, config.Ornament);
                    ImGui.TextColored(V(PaleGold), notice.Title);
                    ImGui.SameLine(); if (ImGui.SmallButton("×")) shown = false;
                    ImGui.TextColored(notice.Kind == NotificationKind.Error ? new Vector4(1, .5f, .4f, 1) : new Vector4(.65f, .8f, 1, 1), notice.Source + (notice.Count > 1 ? " ×" + notice.Count : ""));
                    ImGui.TextWrapped(notice.Text);
                    if (notice.Channel is { } target && ImGui.Button("Open conversation")) { channel = target; Open = true; follow = true; notices.Dismiss(notice.Id); }
                    offset += ImGui.GetWindowSize().Y + 8;
                }
            }
            finally { ImGui.End(); }
            if (!shown) notices.Dismiss(notice.Id);
        }
    }
    private void Settings()
    {
        var shown = SettingsOpen;
        if (ImGui.Begin("Chat and notifications###XivHud.Chat.Settings", ref shown, ImGuiWindowFlags.AlwaysAutoResize))
        {
            var dark = config.DarkPaper; if (ImGui.Checkbox("Dark vellum", ref dark)) { config.DarkPaper = dark; save(); }
            var ornament = config.Ornament; if (ImGui.Checkbox("Brass ornament and stitching", ref ornament)) { config.Ornament = ornament; save(); }
            var enabled = config.Enabled; if (ImGui.Checkbox("Capture new chat in this session", ref enabled)) { config.Enabled = enabled; if (!enabled) { history.Clear(); notices.Clear(); } save(); }
            var notifications = config.Notifications; if (ImGui.Checkbox("Collect notifications", ref notifications)) { config.Notifications = notifications; save(); }
            var tells = config.NotifyTells; if (ImGui.Checkbox("Incoming tells", ref tells)) { config.NotifyTells = tells; save(); }
            var errors = config.NotifyErrors; if (ImGui.Checkbox("Game errors", ref errors)) { config.NotifyErrors = errors; save(); }
            var quests = config.NotifyQuests; if (ImGui.Checkbox("Quest updates", ref quests)) { config.NotifyQuests = quests; save(); }
            var normal = config.NotifyNormal; if (ImGui.Checkbox("Other game toasts", ref normal)) { config.NotifyNormal = normal; save(); }
            if (ImGui.Button("Open conversations")) Open = true;
            ImGui.SameLine(); if (ImGui.Button("Clear chat and notifications")) { history.Clear(); notices.Clear(); }
            ImGui.TextWrapped("Messages are kept only in memory and cleared on logout. The native chat log and native toasts are unchanged. Sending requires explicit input in the composer.");
        }
        ImGui.End(); SettingsOpen = shown;
    }
    private static string ChannelLabel(ChatChannel value) => value == ChatChannel.FreeCompany ? "Free Company" : value.ToString();
    private static Vector4 ChannelColour(ChatChannel value) => value switch
    { ChatChannel.Tell => new(1, .65f, .85f, 1), ChatChannel.Party or ChatChannel.Alliance => new(.6f, .8f, 1, 1), ChatChannel.FreeCompany => new(.65f, .9f, .7f, 1), ChatChannel.System => new(.8f, .75f, .6f, 1), _ => new(.85f, .84f, .79f, 1) };
    private static IReadOnlyList<ChatEntry> Samples() => [new(1, DateTimeOffset.Now, ChatChannel.Party, "A sample companion", "Ready when you are. This is labelled preview data.", false), new(2, DateTimeOffset.Now, ChatChannel.Tell, "A sample friend", "Your conversations and notifications share one interface.", true)];
}
