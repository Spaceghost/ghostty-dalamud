// The widget's only link to Ghostty: IPC into the GhosttyDalamud plugin
// (shim/GhosttyDalamud/GhosttyIpc.cs). No native code or state here. When the
// plugin is not loaded (or is another version) every call fails and the
// widget shows the defaults.
using Dalamud.Plugin.Ipc;
using Umbra.Common;

namespace Umbra.Ghostty;

internal static class GhosttyIpc
{
    private static readonly ICallGateSubscriber<string> StatusGate =
        Framework.DalamudPlugin.GetIpcSubscriber<string>("GhosttyDalamud.v1.Status");
    private static readonly ICallGateSubscriber<(int, int)> PopupSizeGate =
        Framework.DalamudPlugin.GetIpcSubscriber<(int, int)>("GhosttyDalamud.v1.PopupSize");
    private static readonly ICallGateSubscriber<nint, float, float, float, float, int, object> PopupDrawGate =
        Framework.DalamudPlugin.GetIpcSubscriber<nint, float, float, float, float, int, object>("GhosttyDalamud.v1.PopupDraw");
    private static readonly ICallGateSubscriber<object> PopupResetGate =
        Framework.DalamudPlugin.GetIpcSubscriber<object>("GhosttyDalamud.v1.PopupReset");
    private static readonly ICallGateSubscriber<string, object> PostGate =
        Framework.DalamudPlugin.GetIpcSubscriber<string, object>("GhosttyDalamud.v1.Post");

    public static string Status()
    {
        try { return StatusGate.InvokeFunc(); } catch { return "ghostty offline"; }
    }

    public static (int, int) PopupSize()
    {
        try { return PopupSizeGate.InvokeFunc(); } catch { return (900, 480); }
    }

    // flags 0: the core pushes its own mono font
    public static void PopupDraw(nint drawList, float x1, float y1, float x2, float y2)
    {
        try { PopupDrawGate.InvokeAction(drawList, x1, y1, x2, y2, 0); } catch { /* offline */ }
    }

    public static void PopupReset()
    {
        try { PopupResetGate.InvokeAction(); } catch { /* offline */ }
    }

    // a /term command line, e.g. "window"
    public static void Post(string command)
    {
        try { PostGate.InvokeAction(command); } catch { /* offline */ }
    }
}
