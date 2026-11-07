using System.Text;

namespace XivHud.Chat.Core;

public enum ChatChannel { All, Say, Party, Alliance, Tell, FreeCompany, Linkshell, Shout, System, Other }
public sealed record ChatEntry(long Id, DateTimeOffset Timestamp, ChatChannel Channel, string Sender, string Text, bool IncomingTell);

/// <summary>Bounded session-only history. No files, network, native handles or retained event objects.</summary>
public sealed class ChatStore(int capacity = 500)
{
    private readonly object gate = new();
    private readonly Queue<ChatEntry> history = new();
    private readonly Dictionary<ChatChannel, long> read = [];
    private long sequence, revision;
    private readonly int limit = Math.Clamp(capacity, 1, 1000);
    public long Revision { get { lock (gate) return revision; } }
    public ChatEntry? Append(DateTimeOffset timestamp, ChatChannel channel, string sender, string text, bool incomingTell = false)
    {
        sender = Clean(sender, 120); text = Clean(text, 2000);
        if (string.IsNullOrWhiteSpace(text)) return null;
        lock (gate)
        {
            var entry = new ChatEntry(++sequence, timestamp, channel == ChatChannel.All ? ChatChannel.Other : channel, sender, text, incomingTell);
            history.Enqueue(entry); while (history.Count > limit) history.Dequeue(); revision++;
            return entry;
        }
    }
    public IReadOnlyList<ChatEntry> Snapshot(ChatChannel channel = ChatChannel.All, string search = "")
    {
        search = Clean(search, 160);
        lock (gate) return history.Where(x => (channel == ChatChannel.All || x.Channel == channel)
            && (search.Length == 0 || x.Text.Contains(search, StringComparison.OrdinalIgnoreCase) || x.Sender.Contains(search, StringComparison.OrdinalIgnoreCase))).ToArray();
    }
    public int Unread(ChatChannel channel)
    {
        lock (gate) return history.Count(x => (channel == ChatChannel.All || x.Channel == channel) && x.Id > read.GetValueOrDefault(x.Channel));
    }
    public void MarkRead(ChatChannel channel, long through)
    {
        lock (gate)
        {
            through = Math.Min(sequence, Math.Max(0, through));
            foreach (var item in Enum.GetValues<ChatChannel>().Where(x => x != ChatChannel.All && (channel == ChatChannel.All || channel == x)))
                read[item] = Math.Max(read.GetValueOrDefault(item), through);
        }
    }
    public void Clear() { lock (gate) { history.Clear(); read.Clear(); revision++; } }
    public static string Clean(string? text, int limit)
    {
        if (text is null) return "";
        var result = new StringBuilder();
        foreach (var rune in text.EnumerateRunes().Take(Math.Clamp(limit, 0, 4000))) result.Append(Rune.IsControl(rune) ? " " : rune.ToString());
        return result.ToString();
    }
    public static bool IsCombatLog(string kind) => kind is "Damage" or "Miss" or "Action" or "Item" or "Healing" or "GainBuff" or "GainDebuff" or "LoseBuff" or "LoseDebuff";
    public static ChatChannel Classify(string kind) => kind switch
    {
        "Say" or "CustomEmote" or "StandardEmote" => ChatChannel.Say,
        "Party" or "CrossParty" => ChatChannel.Party,
        "Alliance" => ChatChannel.Alliance,
        "TellIncoming" or "TellOutgoing" or "GmTell" => ChatChannel.Tell,
        "FreeCompany" => ChatChannel.FreeCompany,
        "Shout" or "Yell" => ChatChannel.Shout,
        _ when kind.Contains("Linkshell", StringComparison.OrdinalIgnoreCase) || kind.StartsWith("Ls", StringComparison.Ordinal) || kind.StartsWith("CrossLink", StringComparison.Ordinal) => ChatChannel.Linkshell,
        _ when kind.Contains("System", StringComparison.Ordinal) || kind.Contains("Error", StringComparison.Ordinal) => ChatChannel.System,
        _ => ChatChannel.Other,
    };
}
