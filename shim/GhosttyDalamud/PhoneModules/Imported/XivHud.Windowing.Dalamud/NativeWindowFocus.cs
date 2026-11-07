using Dalamud.Bindings.ImGui;

namespace XivHud.Windowing.Dalamud;

/// <summary>Native addon focus alone does not prove ownership: another plugin can take
/// ImGui focus without changing the game's FocusedAddon. A non-null foreign NavWindow
/// therefore wins, including before that plugin has drawn in the current ImGui frame.</summary>
internal static class NativeWindowFocus
{
    public static bool OwnsWindow(ImGuiWindowPtr root, ImGuiWindowPtr candidate) => !root.IsNull && !candidate.IsNull &&
        (candidate == root || candidate.RootWindow == root || candidate.RootWindowPopupTree == root);

    public static bool HasFocus(bool nativeFocused, ImGuiWindowPtr root, ImGuiWindowPtr navWindow) =>
        nativeFocused && (navWindow.IsNull || OwnsWindow(root, navWindow));
}
