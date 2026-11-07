using System.Text.Json;
namespace XivHud.Protocol;

/// <summary>Viewport-relative screen geometry. No monitor, native-addon or world ownership.</summary>
public sealed record ScreenLayout(float X, float Y, float Width, float Height)
{
    public bool Valid => float.IsFinite(X) && float.IsFinite(Y) && float.IsFinite(Width) && float.IsFinite(Height)
        && X >= 0 && Y >= 0 && Width is >= .1f and <= 1 && Height is >= .1f and <= 1
        && X + Width <= 1.001f && Y + Height <= 1.001f;
    public static ScreenLayout Read(JsonElement p) => new(p.GetProperty("x").GetSingle(), p.GetProperty("y").GetSingle(), p.GetProperty("width").GetSingle(), p.GetProperty("height").GetSingle());
}
