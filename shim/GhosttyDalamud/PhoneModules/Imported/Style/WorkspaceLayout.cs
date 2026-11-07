using System.Numerics;
using Dalamud.Bindings.ImGui;
using XivHud.Protocol;
namespace XivHud.Style;

internal sealed class WorkspaceLayout
{
    private ScreenLayout? pending, current;
    internal ScreenLayout? Current => Volatile.Read(ref current);
    internal void Queue(ScreenLayout value) { if (!value.Valid) throw new ArgumentException("Invalid screen layout"); Volatile.Write(ref pending, value); }
    internal ScreenLayout? Take() => Interlocked.Exchange(ref pending, null);
    internal void ApplyNext()
    {
        if (Take() is not { } rect) return;
        var viewport = ImGui.GetMainViewport();
        ImGui.SetNextWindowPos(viewport.WorkPos + viewport.WorkSize * new Vector2(rect.X, rect.Y));
        ImGui.SetNextWindowSize(viewport.WorkSize * new Vector2(rect.Width, rect.Height));
    }
    internal void Observe()
    {
        var v = ImGui.GetMainViewport(); var size = Vector2.Min(ImGui.GetWindowSize() / v.WorkSize, Vector2.One);
        var p = Vector2.Clamp((ImGui.GetWindowPos() - v.WorkPos) / v.WorkSize, Vector2.Zero, Vector2.One - size);
        var rect = new ScreenLayout(p.X, p.Y, size.X, size.Y); if (rect.Valid) Volatile.Write(ref current, rect);
    }
}
