using System.Text;
using System.Text.Json;

namespace XivHud.Windowing;

/// <summary>
/// Uses Ghostty's existing generic ImGui adoption, without loading or modifying Ghostty.
/// All calls must be serialized on the owning module's UI thread. Keep drawing the original
/// window: Ghostty captures its completed draw lists and remaps the pointer itself.
/// </summary>
public class AdoptedWindowHost : IWindowHost
{
    public const string CallChannel = "GhosttyDalamud.v1.Call";
    public const string PostChannel = "GhosttyDalamud.v1.Post";
    private const double PollSeconds = .25;
    private const double RequestTimeout = 5;
    private readonly string provider;
    private readonly string windowName;
    private readonly string caller;
    private readonly Func<string, string> call;
    private readonly Action<string> post;
    private bool disposed, wanted, attempted, ownsWindow, releasePending, releasePosted, returned;
    private double nextPoll, attemptAt, placementAt;
    private long placementRequest;
    private int placementPanelId;
    private bool placementConfirmed, inputFocusRequested;
    private long focusRequest;
    private double focusAt;
    private string? focusError;
    private WindowPlacement? requestedPlacement;
    private string? placementError;

    public AdoptedWindowHost(string windowName, string caller, Func<string, string> call, Action<string> post, string provider = "Ghostty")
    {
        ValidateText(windowName, nameof(windowName));
        var marker = windowName.IndexOf("###", StringComparison.Ordinal);
        if (marker <= 0 || marker + 3 == windowName.Length)
            throw new ArgumentException("Use a visible title followed by a unique ### ImGui identity.", nameof(windowName));
        ValidateText(caller, nameof(caller));
        this.provider = provider;
        this.windowName = windowName;
        this.caller = caller;
        this.call = call ?? throw new ArgumentNullException(nameof(call));
        this.post = post ?? throw new ArgumentNullException(nameof(post));
    }

    public WindowHostState State { get; private set; } = WindowHostState.Screen;
    public string Status { get; private set; } = "Normal window";
    public bool IsHosted => State == WindowHostState.Hosted;
    public int PanelId { get; private set; }

    /// <summary>
    /// True while presentation is hosted or unresolved. Ordinary screen windows still
    /// require the consumer's own current visibility and ImGui focus checks.
    /// </summary>
    public bool RequiresHostFocus => disposed || ownsWindow || releasePending ||
        State is not (WindowHostState.Screen or WindowHostState.ReturnedToScreen);

    /// <summary>
    /// Check on every controller draw before renewing input ownership. Hosted focus uses
    /// Ghostty's latest published snapshot on every access, independently of the slower
    /// placement polling. This never changes focus, placement, or the camera.
    /// </summary>
    public bool HasInputFocus
    {
        get
        {
            if (disposed) return false;
            if (!RequiresHostFocus) return true;
            if (State != WindowHostState.Hosted || !wanted || !ownsWindow || releasePending || PanelId <= 0)
                return false;
            try
            {
                // Recheck the exact adopted identity as well as its id: a provider reload
                // can reuse numeric ids before the next placement poll notices it.
                if (FindPanel() is not { } panel || panel.Id != PanelId) return false;
                var focus = Request("focus.get");
                return focus.TryGetProperty("id", out var id) && id.TryGetInt32(out var value) && value == PanelId &&
                    focus.TryGetProperty("kind", out var kind) && kind.ValueKind == JsonValueKind.String &&
                    kind.GetString() is "window" or "terminal";
                // Ghostty currently reports adopted Panel transports as "terminal" in
                // focus.get. Ownership comes from the exact adopted identity above.
            }
            catch { return false; }
        }
    }

    /// <summary>
    /// Explicit user intent to focus an opened HUD presentation. Call only for a user
    /// open/toggle/enable action, never from every draw. Placement must be acknowledged
    /// before one exact-panel focus request is sent; actual input still uses HasInputFocus.
    /// Other world placements are refused, without moving the player or camera.
    /// </summary>
    public void RequestInputFocus()
    {
        if (disposed || inputFocusRequested || focusRequest != 0) return;
        inputFocusRequested = true;
        focusError = null;
        nextPoll = double.NegativeInfinity;
    }

    public void Update(bool enabled, bool isOpen, bool loggedIn, double now, WindowPlacement placement = WindowPlacement.Companion)
    {
        if (disposed) return;
        if (!double.IsFinite(now)) throw new ArgumentOutOfRangeException(nameof(now));
        if (!Enum.IsDefined(placement)) throw new ArgumentOutOfRangeException(nameof(placement));
        var requested = enabled && isOpen && loggedIn;
        if (requested != wanted)
        {
            wanted = requested;
            nextPoll = now;
            if (!wanted) BeginRelease();
            else
            {
                attempted = false;
                returned = false;
                requestedPlacement = null;
                placementError = null;
            }
        }

        if (releasePending)
        {
            if (now < nextPoll) return;
            nextPoll = now + PollSeconds;
            Release(now);
            return;
        }
        if (!wanted)
        {
            ResetInputFocus();
            Set(WindowHostState.Screen, "Normal window");
            return;
        }
        if (returned)
        {
            ResetInputFocus();
            Set(WindowHostState.ReturnedToScreen, "Returned to the normal window; reopen it or choose Try again to place it in the world");
            return;
        }
        if (now < nextPoll) return;
        nextPoll = now + PollSeconds;

        try
        {
            var panel = FindPanel();
            if (panel is { } found)
            {
                PanelId = found.Id;
                ownsWindow = true;
                attempted = true;
                Set(WindowHostState.Hosted, "World window · " + found.View);
                UpdatePlacement(placement, now);
                UpdateInputFocus(found.View, placement, now);
                return;
            }

            if (PanelId != 0)
            {
                // Ghostty's close/back-to-UI button belongs to the user. Do not fight it.
                PanelId = 0;
                ownsWindow = false;
                returned = true;
                ResetInputFocus();
                Set(WindowHostState.ReturnedToScreen, "Returned to the normal window");
                return;
            }
            if (attempted)
            {
                if (now - attemptAt >= RequestTimeout)
                {
                    // Post has no acknowledgement. Cancel the exact queued adoption so a
                    // late core frame cannot leave an orphan after we report a failure.
                    returned = true;
                    BeginRelease();
                    Release(now);
                    if (!releasePending) Set(WindowHostState.Unavailable, $"{provider} did not adopt this window; Try again when it is ready");
                }
                else Set(WindowHostState.Adopting, $"Waiting for {provider} to adopt this window");
                return;
            }

            // Read support first; never send an untrackable adoption to an old/missing core.
            // Record intent before sending: a provider may enqueue the command and then
            // throw. The exact-name cleanup must still cover that ambiguous outcome.
            ownsWindow = true;
            attempted = true;
            attemptAt = now;
            post("adopt " + windowName);
            Set(WindowHostState.Adopting, $"Waiting for {provider} to adopt this window");
        }
        catch (Exception ex)
        {
            // A transport can disappear between any two calls. Drawing the ordinary window
            // continues; pending ownership is retained so a later close still releases it.
            Set(WindowHostState.WaitingForHost, "Normal window · " + Error(ex));
            nextPoll = now + 1;
        }
    }

    public void Retry()
    {
        if (disposed) return;
        BeginRelease();
        attempted = false;
        returned = false;
        requestedPlacement = null;
        placementError = null;
        nextPoll = double.NegativeInfinity;
    }

    public void ReturnToScreen()
    {
        if (disposed) return;
        returned = true;
        BeginRelease();
        nextPoll = double.NegativeInfinity;
        if (!releasePending) Set(WindowHostState.ReturnedToScreen, "Normal window");
    }

    private void BeginRelease()
    {
        ResetInputFocus();
        if (!ownsWindow) return;
        releasePending = true;
        releasePosted = false;
        placementRequest = 0;
        placementConfirmed = false;
        requestedPlacement = null;
        Set(WindowHostState.Returning, "Returning to the normal window");
    }

    private void Release(double now)
    {
        try
        {
            if (!releasePosted)
            {
                // Named release is safe even if an adoption has not reached its first frame.
                // Never use the command's unnamed focused/newest-window fallback.
                post("release " + windowName);
                releasePosted = true;
                nextPoll = now + PollSeconds;
                return;
            }
            if (FindPanel() != null) return;
            releasePending = releasePosted = ownsWindow = false;
            PanelId = 0;
            Set(returned ? WindowHostState.ReturnedToScreen : WindowHostState.Screen, "Normal window");
        }
        catch (Exception ex)
        {
            releasePosted = false;
            Set(WindowHostState.Returning, "Release pending · " + Error(ex));
            nextPoll = now + 1;
        }
    }

    private void UpdatePlacement(WindowPlacement placement, double now)
    {
        if (requestedPlacement != placement || placementPanelId != PanelId)
        {
            requestedPlacement = placement;
            placementPanelId = PanelId;
            placementRequest = 0;
            placementConfirmed = false;
            placementError = null;
            try
            {
                var result = Request("panel.place", new { id = PanelId, pin = PlacementArgument(placement) });
                if (!result.TryGetProperty("queued", out var queued) || queued.ValueKind != JsonValueKind.True ||
                    !result.TryGetProperty("request", out var request) || !request.TryGetInt64(out placementRequest) || placementRequest <= 0)
                    throw new InvalidOperationException($"{provider} did not acknowledge the placement request");
                placementAt = now;
            }
            catch (Exception ex) { placementError = Error(ex); }
        }
        if (placementRequest != 0)
        {
            try
            {
                var result = Request("window.list");
                if (result.TryGetProperty("requests", out var requests) && requests.ValueKind == JsonValueKind.Array)
                {
                    foreach (var entry in requests.EnumerateArray())
                    {
                        if (!entry.TryGetProperty("request", out var id) || !id.TryGetInt64(out var value) || value != placementRequest) continue;
                        placementRequest = 0;
                        if (!entry.TryGetProperty("ok", out var ok) || ok.ValueKind != JsonValueKind.True)
                            placementError = Message(entry, $"{provider} refused that placement");
                        else
                        {
                            placementError = null;
                            placementConfirmed = true;
                        }
                        break;
                    }
                }
            }
            catch (Exception ex) { placementError = Error(ex); }
            if (placementRequest != 0 && now - placementAt >= RequestTimeout)
            {
                placementRequest = 0;
                placementError = "Placement was not confirmed; choose Try again to retry";
            }
        }
        if (placementError != null) Status += " · " + placementError;
        else if (placementRequest != 0) Status += " · placing…";
    }

    private void UpdateInputFocus(string view, WindowPlacement placement, double now)
    {
        if (placement != WindowPlacement.Hud)
        {
            ResetInputFocus();
            return;
        }
        if (inputFocusRequested && placementConfirmed && placementPanelId == PanelId &&
            placementRequest == 0 && placementError == null && view == "hud")
        {
            // Consume intent before invoking IPC. Even an ambiguous enqueue-then-throw
            // must never repeat a focus change and steal input back from another window.
            inputFocusRequested = false;
            try
            {
                var result = Request("window.focus", new { id = PanelId });
                if (!result.TryGetProperty("queued", out var queued) || queued.ValueKind != JsonValueKind.True ||
                    !result.TryGetProperty("request", out var request) || !request.TryGetInt64(out focusRequest) || focusRequest <= 0)
                    throw new InvalidOperationException($"{provider} did not acknowledge the focus request");
                focusAt = now;
            }
            catch (Exception ex)
            {
                focusRequest = 0;
                focusError = Error(ex);
            }
        }
        if (focusRequest != 0)
        {
            try
            {
                var result = Request("window.list");
                if (result.TryGetProperty("requests", out var requests) && requests.ValueKind == JsonValueKind.Array)
                {
                    foreach (var entry in requests.EnumerateArray())
                    {
                        if (!entry.TryGetProperty("request", out var id) || !id.TryGetInt64(out var value) || value != focusRequest) continue;
                        focusRequest = 0;
                        focusError = entry.TryGetProperty("ok", out var ok) && ok.ValueKind == JsonValueKind.True
                            ? null : Message(entry, $"{provider} refused input focus");
                        break;
                    }
                }
            }
            catch (Exception ex) { focusError = Error(ex); }
            if (focusRequest != 0 && now - focusAt >= RequestTimeout)
            {
                focusRequest = 0;
                focusError = "Input focus was not confirmed; open the window again to retry";
            }
        }
        if (focusError != null) Status += " · " + focusError;
        else if (focusRequest != 0) Status += " · requesting input focus…";
    }

    private void ResetInputFocus()
    {
        inputFocusRequested = false;
        focusRequest = 0;
        focusError = null;
    }

    private (int Id, string View)? FindPanel()
    {
        var result = Request("panel.list");
        if (!result.TryGetProperty("panels", out var panels) || panels.ValueKind != JsonValueKind.Array)
            throw new InvalidOperationException($"{provider}'s panel list is unavailable");
        (int Id, string View)? found = null;
        foreach (var panel in panels.EnumerateArray())
        {
            if (!panel.TryGetProperty("kind", out var kind) || kind.GetString() != "adopted" ||
                !panel.TryGetProperty("app", out var app) || app.GetString() != windowName) continue;
            if (!panel.TryGetProperty("id", out var id) || !id.TryGetInt32(out var value) || value <= 0)
                throw new InvalidOperationException($"{provider} returned an invalid window identity");
            if (found != null) throw new InvalidOperationException($"{provider} returned an ambiguous window identity");
            found = (value, panel.TryGetProperty("view", out var view) && view.ValueKind == JsonValueKind.String ? view.GetString()! : "world");
        }
        return found;
    }

    private JsonElement Request(string method, object? parameters = null)
    {
        var json = call(JsonSerializer.Serialize(new { method, @params = parameters, caller }));
        if (json.Length > 65536) throw new InvalidOperationException($"{provider} returned an oversized reply");
        using var document = JsonDocument.Parse(json);
        var root = document.RootElement;
        if (!root.TryGetProperty("ok", out var ok) || ok.ValueKind != JsonValueKind.True)
            throw new InvalidOperationException(Message(root, $"{provider} is unavailable"));
        if (!root.TryGetProperty("result", out var result)) throw new InvalidOperationException($"{provider} returned an incomplete reply");
        return result.Clone();
    }

    public static string PlacementArgument(WindowPlacement placement) => placement switch
    {
        WindowPlacement.Companion => "pet",
        WindowPlacement.Hud => "hud",
        WindowPlacement.World => "here",
        WindowPlacement.Ground => "ground",
        _ => throw new ArgumentOutOfRangeException(nameof(placement)),
    };

    private static string Message(JsonElement element, string fallback) =>
        element.TryGetProperty("error", out var error) && error.ValueKind == JsonValueKind.String ? error.GetString()! : fallback;
    private string Error(Exception ex) => string.IsNullOrWhiteSpace(ex.Message) ? $"{provider} is unavailable" : ex.Message;
    private void Set(WindowHostState state, string status) { State = state; Status = status; }
    private static void ValidateText(string value, string name)
    {
        if (string.IsNullOrWhiteSpace(value) || value != value.Trim() || value.Any(char.IsControl) || Encoding.UTF8.GetByteCount(value) > 1024)
            throw new ArgumentException("Use a nonempty name of at most 1024 UTF-8 bytes without control characters or surrounding spaces.", name);
    }

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        ResetInputFocus();
        if (ownsWindow)
        {
            try { post("release " + windowName); }
            catch (Exception ex) { Status = "Release unavailable during unload · " + Error(ex); }
        }
        PanelId = 0;
        State = WindowHostState.Disposed;
    }
}

/// <summary>Existing Ghostty provider, preserving its protocol, ownership and behavior.</summary>
public sealed class GhosttyWindowHost(string windowName, string caller, Func<string, string> call, Action<string> post)
    : AdoptedWindowHost(windowName, caller, call, post);

/// <summary>Independent presentation service; no Ghostty or terminal allocation.</summary>
public sealed class FloatingWindowHost(string windowName, string caller, Func<string, string> call, Action<string> post)
    : AdoptedWindowHost(windowName, caller, call, post, "Floating windows")
{
    public new const string CallChannel = "XivHud.Windows.v1.Call";
    public new const string PostChannel = "XivHud.Windows.v1.Post";
}
