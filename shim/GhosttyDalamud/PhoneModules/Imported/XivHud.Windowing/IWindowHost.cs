namespace XivHud.Windowing;

public enum WindowPlacement { Companion, Hud, World, Ground }
public enum WindowHostState { Screen, WaitingForHost, Adopting, Hosted, Returning, ReturnedToScreen, Unavailable, Disposed }

/// <summary>
/// Optional presentation of an existing, normally drawn window. Call on the UI thread after
/// drawing, including when the window is closed. The host never owns the module's open state.
/// </summary>
public interface IWindowHost : IDisposable
{
    WindowHostState State { get; }
    string Status { get; }
    bool IsHosted { get; }
    int PanelId { get; }
    void Update(bool enabled, bool isOpen, bool loggedIn, double now, WindowPlacement placement = WindowPlacement.Companion);
    void Retry();
    void ReturnToScreen();
}
