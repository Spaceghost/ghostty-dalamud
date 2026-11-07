using System.Numerics;

namespace XivHud.Journal;

internal readonly record struct JournalPopupRectangle(Vector2 Position, Vector2 Size);

/// <summary>Owned popup geometry stays inside the actual book surface before any capture.</summary>
internal static class JournalPopupLayout
{
    internal static JournalPopupRectangle Fit(Vector2 rootPosition, Vector2 rootSize, Vector2 preferred, float scale)
    {
        if (!Finite(rootPosition) || !Finite(rootSize) || !Finite(preferred) ||
            rootSize.X <= 0 || rootSize.Y <= 0 || preferred.X <= 0 || preferred.Y <= 0 || !float.IsFinite(scale) || scale <= 0)
            throw new ArgumentOutOfRangeException(nameof(rootSize));
        var inset = MathF.Min(18 * scale, MathF.Min(rootSize.X, rootSize.Y) / 4);
        var size = Vector2.Min(preferred, rootSize - new Vector2(inset * 2));
        return new(rootPosition + (rootSize - size) / 2, size);
    }
    private static bool Finite(Vector2 value) => float.IsFinite(value.X) && float.IsFinite(value.Y);
}
