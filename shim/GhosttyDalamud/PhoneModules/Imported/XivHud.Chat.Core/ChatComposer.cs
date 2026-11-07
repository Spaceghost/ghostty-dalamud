using System.Text;

namespace XivHud.Chat.Core;

public sealed record SendIntent(ulong Player, string Line, long CreatedAt, string Draft = "");
public static class ChatComposer
{
    public const int MaximumBytes = 500;
    public static string? Build(ChatChannel channel, string text, string recipient, out string? error)
    {
        error = null;
        if (string.IsNullOrWhiteSpace(text)) { error = "Enter a message"; return null; }
        if (text.Any(char.IsControl) || text.TrimStart().StartsWith('/')) { error = "Enter plain message text; commands belong in the game chat box"; return null; }
        string? prefix = channel switch { ChatChannel.Say => "/s ", ChatChannel.Party => "/p ", ChatChannel.Alliance => "/a ", ChatChannel.FreeCompany => "/fc ", _ => null };
        if (channel == ChatChannel.Tell)
        {
            var parts = recipient.Trim().Split('@');
            if (parts.Length != 2 || parts[0].Split(' ', StringSplitOptions.RemoveEmptyEntries).Length != 2 || parts.Any(string.IsNullOrWhiteSpace)
                || recipient.Length > 100 || !parts[1].All(char.IsLetter) || recipient.Any(c => !char.IsLetter(c) && c is not (' ' or '-' or '\'' or '@')))
            { error = "Tell recipient must be Firstname Lastname@World"; return null; }
            prefix = "/tell " + string.Join(" ", parts[0].Split(' ', StringSplitOptions.RemoveEmptyEntries)) + "@" + parts[1] + " ";
        }
        if (prefix is null) { error = "Choose Say, Party, Alliance, Free Company or Tell to compose"; return null; }
        var line = prefix + text;
        if (Encoding.UTF8.GetByteCount(line) > MaximumBytes) { error = "Message exceeds the game's 500-byte limit"; return null; }
        return line;
    }
    public static bool CanSubmit(SendIntent intent, ulong currentPlayer, long now, bool enabled, bool allowed, bool preview)
        => enabled && allowed && !preview && currentPlayer != 0 && currentPlayer == intent.Player
        && now >= intent.CreatedAt && now - intent.CreatedAt <= 1000 && intent.Line.Length > 0
        && Encoding.UTF8.GetByteCount(intent.Line) <= MaximumBytes && !intent.Line.Any(char.IsControl) && IsSafeLine(intent.Line);
    private static bool IsSafeLine(string line)
    {
        foreach (var (prefix, channel) in new[] { ("/s ", ChatChannel.Say), ("/p ", ChatChannel.Party), ("/a ", ChatChannel.Alliance), ("/fc ", ChatChannel.FreeCompany) })
            if (line.StartsWith(prefix, StringComparison.Ordinal)) return Build(channel, line[prefix.Length..], "", out _) == line;
        if (!line.StartsWith("/tell ", StringComparison.Ordinal)) return false;
        var pieces = line[6..].Split(' ', 3, StringSplitOptions.RemoveEmptyEntries);
        return pieces.Length == 3 && Build(ChatChannel.Tell, pieces[2], pieces[0] + " " + pieces[1], out _) == line;
    }
}
