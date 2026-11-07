using System.Numerics;

namespace XivHud.Journal;

internal static class JournalTrackerPolicy
{
    internal static JournalEntry[] Select(IEnumerable<JournalEntry> entries, IReadOnlySet<uint> bookmarks, bool bookmarkedOnly, int limit)
        => entries.Where(q => !q.Hidden && (bookmarkedOnly ? bookmarks.Contains(q.Id) : q.Tracked))
            .OrderByDescending(q => q.Priority).ThenBy(q => q.Name, StringComparer.CurrentCultureIgnoreCase)
            .ThenBy(q => q.Id).Take(Math.Clamp(limit, 1, 5)).ToArray();

    internal static string Objective(JournalEntry entry) => entry.ReadyToComplete ? "Ready to complete"
        : entry.Objectives.Count == 0 ? "Open Journal for the current objective." : string.Join("\n", entry.Objectives);

    internal static Vector2 Anchor(Vector2 value) => float.IsFinite(value.X) && float.IsFinite(value.Y)
        ? Vector2.Clamp(value, Vector2.Zero, Vector2.One) : new(.98f, .58f);

    internal static Vector2 Position(Vector2 origin, Vector2 viewport, Vector2 size, Vector2 anchor)
        => origin + Vector2.Max(Vector2.Zero, viewport - size) * Anchor(anchor);

    internal static Vector2 FromPosition(Vector2 position, Vector2 origin, Vector2 viewport, Vector2 size)
    {
        var travel = Vector2.Max(Vector2.Zero, viewport - size);
        return new(travel.X > 0 ? Math.Clamp((position.X - origin.X) / travel.X, 0, 1) : 0,
            travel.Y > 0 ? Math.Clamp((position.Y - origin.Y) / travel.Y, 0, 1) : 0);
    }
}
