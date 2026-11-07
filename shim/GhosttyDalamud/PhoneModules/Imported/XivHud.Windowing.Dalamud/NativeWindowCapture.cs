using System.Numerics;
using Dalamud.Bindings.ImGui;

namespace XivHud.Windowing.Dalamud;

public readonly unsafe struct NativeWindowDrawFrame(ImDrawData* data)
{
    public readonly ImDrawData* Data = data;
}

/// <summary>Matches Dalamud's own ResizeAndDrawWindow traversal and additionally includes only
/// this root's popup trees. Uses the installed typed bindings; no pointer survives this call.</summary>
public static unsafe class NativeWindowCapture
{
    public static bool Draw(string name, Vector2 position, Vector2 size, Func<NativeWindowDrawFrame, bool> present)
    {
        var root = ImGuiP.FindWindowByName(name);
        var context = ImGui.GetCurrentContext();
        if (root.IsNull || context.IsNull || !root.Active || root.Hidden) return false;
        if (context.Windows.Size is < 0 or > 4096) throw new InvalidOperationException("Unexpected ImGui window count");
        return DrawOwned(root, new ReadOnlySpan<ImGuiWindowPtr>(context.Windows.Data, context.Windows.Size), position, size, present);
    }

    /// <summary>Standalone floating capture also includes popup extents, without clipping menus to the root.</summary>
    public static bool DrawExpanded(string name, Func<NativeWindowDrawFrame, bool> present)
    {
        var root = ImGuiP.FindWindowByName(name);
        var context = ImGui.GetCurrentContext();
        if (root.IsNull || context.IsNull || !root.Active || root.Hidden) return false;
        if (context.Windows.Size is < 0 or > 4096) throw new InvalidOperationException("Unexpected ImGui window count");
        var position = root.Pos; var end = root.Pos + root.Size;
        var all = new ReadOnlySpan<ImGuiWindowPtr>(context.Windows.Data, context.Windows.Size);
        foreach (var window in all)
            if (!window.IsNull && window.Active && !window.Hidden && window.RootWindowPopupTree == root)
            { position = Vector2.Min(position, window.Pos); end = Vector2.Max(end, window.Pos + window.Size); }
        var size = end - position;
        if (size.X < 32 || size.Y < 32 || size.X > 4096 || size.Y > 4096) throw new InvalidOperationException("Floating capture size exceeds supported bounds");
        return DrawOwned(root, all, position, size, present, true);
    }

    internal static bool DrawOwned(ImGuiWindowPtr root, ReadOnlySpan<ImGuiWindowPtr> allWindows,
        Vector2 position, Vector2 size, Func<NativeWindowDrawFrame, bool> present, bool allowOverflow = false)
    {
        if (root.IsNull || !root.Active || root.Hidden) return false;
        if (!allowOverflow && (Vector2.Distance(root.Pos, position) > 2 || Vector2.Distance(root.Size, size) > 2))
            throw new InvalidOperationException("The owned ImGui root does not match the native content rectangle");
        var windows = new List<ImGuiWindowPtr>(16);
        var seen = new HashSet<nint>();
        AddTree(root);
        if (allWindows.Length > 4096) throw new InvalidOperationException("Unexpected ImGui window count");
        foreach (var candidate in allWindows)
            if (candidate != root && candidate.Active && !candidate.Hidden && candidate.RootWindowPopupTree == root)
                AddTree(candidate);
        if (windows.Count == 0) return false;
        ImDrawList** lists = stackalloc ImDrawList*[windows.Count];
        var data = new ImDrawData { Valid = 1, CmdListsCount = windows.Count, CmdLists = lists,
            DisplayPos = position, DisplaySize = size, FramebufferScale = Vector2.One };
        for (var i = 0; i < windows.Count; i++)
        {
            var list = windows[i].DrawList;
            for (var j = 0; j < list.CmdBuffer.Size; j++)
                if (list.CmdBuffer[j].UserCallback != null)
                    throw new InvalidOperationException("Native texture capture does not support draw callbacks");
            data.CmdLists[i] = list;
            data.TotalIdxCount = checked(data.TotalIdxCount + list.IdxBuffer.Size);
            data.TotalVtxCount = checked(data.TotalVtxCount + list.VtxBuffer.Size);
        }
        if (!present(new NativeWindowDrawFrame(&data))) return false;
        // Only after a successful draw. Do not touch vertex/index buffers, input events,
        // unrelated window lists, or the global foreground/background draw lists.
        foreach (var window in windows) window.DrawList.CmdBuffer.Clear();
        return true;

        void AddTree(ImGuiWindowPtr window)
        {
            if (!seen.Add((nint)window.Handle) || !window.Active || window.Hidden) return;
            if (seen.Count > 128) throw new InvalidOperationException("Too many owned child/popup windows");
            if (!allowOverflow && (window.Flags & ImGuiWindowFlags.Popup) != 0 &&
                (window.Pos.X < position.X - 1 || window.Pos.Y < position.Y - 1 ||
                 window.Pos.X + window.Size.X > position.X + size.X + 1 || window.Pos.Y + window.Size.Y > position.Y + size.Y + 1))
                throw new InvalidOperationException("An owned popup extends beyond the native content area");
            if (window.DrawList.CmdBuffer.Size > 0) windows.Add(window);
            for (var i = 0; i < window.DC.ChildWindows.Size; i++) AddTree(window.DC.ChildWindows[i]);
        }
    }
}
