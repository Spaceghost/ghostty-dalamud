namespace XivHud.Windowing;

/// <summary>Switch providers only after the old owner has released the source.</summary>
public sealed class WindowHostRouter : IWindowHost
{
    private readonly AdoptedWindowHost floating, ghostty;
    private AdoptedWindowHost active;
    public WindowHostRouter(AdoptedWindowHost floating, AdoptedWindowHost ghostty)
    { this.floating = floating; this.ghostty = ghostty; active = floating; }
    private bool focusRequested;
    public bool UseGhostty { get; set; }
    public WindowHostState State => active.State;
    public string Status => active.Status;
    public bool IsHosted => active.IsHosted;
    public int PanelId => active.PanelId;
    public bool RequiresHostFocus => active.RequiresHostFocus;
    public bool HasInputFocus => active.HasInputFocus;
    public void RequestInputFocus() => focusRequested = true;
    public void Retry() => active.Retry();
    public void ReturnToScreen() { focusRequested = false; active.ReturnToScreen(); }
    public void Update(bool enabled, bool isOpen, bool loggedIn, double now, WindowPlacement placement = WindowPlacement.Companion)
    {
        var desired = UseGhostty ? ghostty : floating;
        if (active != desired)
        {
            active.Update(false, isOpen, loggedIn, now, placement);
            if (active.RequiresHostFocus) return;
            active = desired; active.Retry();
        }
        if (focusRequested && enabled && isOpen) { focusRequested = false; active.RequestInputFocus(); }
        active.Update(enabled, isOpen, loggedIn, now, placement);
    }
    public void Dispose() { floating.Dispose(); ghostty.Dispose(); }
}
