using System.Numerics;
using Dalamud.Bindings.ImGui;

namespace XivSpell;

internal sealed partial class Plugin
{
    private static readonly Vector2[] EditorOutlineOffsets = [
        new(-1, -1), new(0, -1), new(1, -1), new(-1, 0),
        new(1, 0), new(-1, 1), new(0, 1), new(1, 1),
    ];

    private static void DrawEditorOutline(ImDrawListPtr draw, Vector2 position, string text, float wrapWidth = 0)
    {
        if (text.Length == 0) return;
        var font = ImGui.GetFont();
        var size = ImGui.GetFontSize();
        var radius = Math.Clamp(size / 16, 1, 1.6f);
        draw.AddText(font, size, position + new Vector2(2, 3) * radius, 0xB8000000, text, wrapWidth);
        foreach (var offset in EditorOutlineOffsets)
            draw.AddText(font, size, position + offset * radius, 0xFF050302, text, wrapWidth);
    }

    private static void EditorLabel(string text, Vector4 color, bool wrap = false)
    {
        if (text.Length == 0) return;
        var position = ImGui.GetCursorScreenPos();
        var width = wrap ? MathF.Max(1, ImGui.GetContentRegionAvail().X) : 0;
        var size = ImGui.CalcTextSize(text, false, width > 0 ? width : -1);
        ImGui.Dummy(size);
        var draw = ImGui.GetWindowDrawList();
        DrawEditorOutline(draw, position, text, width);
        draw.AddText(ImGui.GetFont(), ImGui.GetFontSize(), position, ImGui.ColorConvertFloat4ToU32(color), text, width);
    }

    private static unsafe void OutlineEditorSource(uint inputId, string text)
    {
        // InputTextMultiline renders its editable text in a child draw list.
        // Put only its outline in the parent: ImGui renders the child afterward,
        // leaving the real text, caret, selection and IME completely native.
        var parent = ImGuiP.GetCurrentWindow();
        if (parent.IsNull || text.Length == 0) return;
        var children = parent.DC.ChildWindows;
        for (var i = 0; i < children.Size; i++) {
            var child = children[i];
            if (child.IsNull || child.ChildId != inputId) continue;
            var state = ImGuiP.GetInputTextState(inputId);
            var active = ImGuiP.GetActiveID();
            var rendersCaret = active == inputId || active == ImGuiP.GetWindowScrollbarID(child, ImGuiAxis.Y);
            var horizontalScroll = state.IsNull || !rendersCaret ? 0 : state.ScrollX;
            var position = child.Pos + ImGui.GetStyle().FramePadding - new Vector2(horizontalScroll, child.Scroll.Y);
            var clip = child.InnerClipRect;
            var draw = ImGui.GetWindowDrawList();
            draw.PushClipRect(clip.Min, clip.Max, true);
            DrawEditorOutline(draw, position, text);
            draw.PopClipRect();
            return;
        }
    }
}
