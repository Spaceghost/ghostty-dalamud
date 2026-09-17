// IPC the Umbra toolbar widget calls (shim/Umbra.Ghostty/GhosttyIpc.cs).
// Registered and unregistered only when the core asks, through GuHostApi.
// Channel names carry a version: a widget from another version sees nothing
// and reads as offline.
using Dalamud.Plugin.Ipc;

namespace GhosttyDalamud;

internal static unsafe class GhosttyIpc
{
    private static ICallGateProvider<string>? _status;
    private static ICallGateProvider<(int, int)>? _popupSize;
    private static ICallGateProvider<nint, float, float, float, float, int, object>? _popupDraw;
    private static ICallGateProvider<object>? _popupReset;
    private static ICallGateProvider<string, object>? _post;

    public static void Register()
    {
        _status = Plugin.Pi.GetIpcProvider<string>("GhosttyDalamud.v1.Status");
        _status.RegisterFunc(Native.StatusText);
        _popupSize = Plugin.Pi.GetIpcProvider<(int, int)>("GhosttyDalamud.v1.PopupSize");
        _popupSize.RegisterFunc(PopupSize);
        _popupDraw = Plugin.Pi.GetIpcProvider<nint, float, float, float, float, int, object>("GhosttyDalamud.v1.PopupDraw");
        _popupDraw.RegisterAction(PopupDraw);
        _popupReset = Plugin.Pi.GetIpcProvider<object>("GhosttyDalamud.v1.PopupReset");
        _popupReset.RegisterAction(PopupReset);
        _post = Plugin.Pi.GetIpcProvider<string, object>("GhosttyDalamud.v1.Post");
        _post.RegisterAction(Post);
    }

    public static void Unregister()
    {
        _status?.UnregisterFunc();
        _popupSize?.UnregisterFunc();
        _popupDraw?.UnregisterAction();
        _popupReset?.UnregisterAction();
        _post?.UnregisterAction();
        _status = null;
        _popupSize = null;
        _popupDraw = null;
        _popupReset = null;
        _post = null;
    }

    private static (int, int) PopupSize()
    {
        int w = 0, h = 0;
        Native.PopupSize(&w, &h);
        return (w, h);
    }

    private static void PopupDraw(nint drawList, float x1, float y1, float x2, float y2, int flags)
        => Native.PopupDraw(drawList, x1, y1, x2, y2, flags);

    private static void PopupReset() => Native.PopupReset();

    // a /term command line from the widget, e.g. "window"
    private static void Post(string text) => Native.Post(GuEvent.Chat, 0, 0, 0, 0, text);
}
