using System.Globalization;

namespace XivHud.Journal;

/// <summary>Quest sheet keys and current-step selection. Does not select future journal narrative.</summary>
internal static class JournalText
{
    internal const uint QuestRowBase = 0x10000;

    internal static bool TryClientId(uint id, out ushort clientId)
    {
        clientId = 0;
        if (id is 0 or > 0x1FFFF || id == QuestRowBase) return false;
        clientId = (ushort)(id & 0xFFFF);
        return true;
    }

    internal static string? SheetPath(string key)
    {
        var split = key.LastIndexOf('_');
        if (split < 0 || key.Length - split - 1 < 5 || key.IndexOfAny(['/', '\\']) >= 0) return null;
        var digits = key.AsSpan(split + 1, 5);
        foreach (var c in digits) if (!char.IsAsciiDigit(c)) return null;
        return $"quest/{digits[..3]}/{key}";
    }

    internal static int? TodoIndex(string key)
    {
        const string marker = "_TODO_";
        var at = key.LastIndexOf(marker, StringComparison.OrdinalIgnoreCase);
        if (at < 0) return null;
        var tail = key.AsSpan(at + marker.Length);
        return tail.Length is > 0 and <= 3 && int.TryParse(tail, NumberStyles.None,
            CultureInfo.InvariantCulture, out var index) ? index : null;
    }

    internal static string[] CurrentObjectives(IEnumerable<JournalTodo> todos, int sequence) => todos
        .Where(todo => todo.Sequence != 0 && todo.Sequence == sequence && !string.IsNullOrWhiteSpace(todo.Text))
        .Select(todo => todo.Text.Trim())
        .Distinct(StringComparer.Ordinal)
        .ToArray();
}

internal sealed record JournalTodo(byte Sequence, string Text);
