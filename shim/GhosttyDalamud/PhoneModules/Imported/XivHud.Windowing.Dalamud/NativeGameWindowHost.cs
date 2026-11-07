using System.Numerics;
using System.Runtime.CompilerServices;
using Dalamud.Bindings.ImGui;
using Dalamud.IoC;
using Dalamud.Plugin;
using Dalamud.Plugin.Services;

namespace XivHud.Windowing.Dalamud;

/// <summary>A real game window containing the caller's explicitly owned ImGui root.
/// Call Prepare before that root is drawn, ApplyNextWindowLayout immediately before Begin,
/// and Capture after all of its children/popups have ended. No global ImGui/native hooks.</summary>
public sealed class NativeGameWindowHost : IDisposable
{
    private readonly IDalamudPluginInterface pi;
    private readonly string windowName, nativeName, title;
    private readonly Vector2 initialSize;
    private NativeWindowServices? services;
    private INativeWindowBackend? backend;
    private readonly NativeWindowShutdown shutdown = new();
    private bool disposed, failed, wasActive, restorePending, wasRequested, focusOnFirstReady;
    private Vector2 savedPosition, savedSize;
    private NativeWindowSnapshot snapshot;

    public NativeGameWindowHost(IDalamudPluginInterface pi, string windowName, string nativeName,
        string title, Vector2 initialContentSize)
    {
        this.pi = pi ?? throw new ArgumentNullException(nameof(pi));
        if (string.IsNullOrWhiteSpace(windowName) || !windowName.Contains("###", StringComparison.Ordinal) || windowName.Any(char.IsControl))
            throw new ArgumentException("Use the exact owned ImGui name with its ### identity.", nameof(windowName));
        if (nativeName is not { Length: > 0 and <= 31 } || !nativeName.All(c => char.IsAsciiLetterOrDigit(c) || c == '_'))
            throw new ArgumentException("Use a unique native addon name of up to31 ASCII letters, digits or underscores.", nameof(nativeName));
        if (string.IsNullOrWhiteSpace(title) || title.Length > 128 || title.Any(char.IsControl)) throw new ArgumentException("Invalid title.", nameof(title));
        if (!ValidSize(initialContentSize)) throw new ArgumentOutOfRangeException(nameof(initialContentSize));
        this.windowName = windowName; this.nativeName = nativeName; this.title = title; initialSize = initialContentSize;
    }

    public bool IsActive { get; private set; }
    public bool ShouldDraw { get; private set; } = true;
    public bool CloseRequested => wasRequested && snapshot.UserClosed;
    public bool AllowInput => !IsActive || snapshot.AllowInput;
    public bool IsFocused
    {
        get
        {
            if (!IsActive || !snapshot.Focused) return false;
            var context = ImGui.GetCurrentContext();
            return !context.IsNull && NativeWindowFocus.HasFocus(true, ImGuiP.FindWindowByName(windowName), context.NavWindow);
        }
    }
    public Vector2 ContentPosition => snapshot.Position;
    public Vector2 ContentSize => snapshot.Size;
    public float Scale => IsActive ? snapshot.Scale : 1;
    public string Status { get; private set; } = "Normal window";
    /// <summary>Includes the current backend and any earlier retry retirements. After Dispose,
    /// await this off the game thread before releasing the plugin interface or its services.</summary>
    public Task ShutdownTask => shutdown.Completion;

    public void Prepare(bool enabled, bool isOpen, bool loggedIn)
    {
        if (disposed) return;
        var wanted = enabled && isOpen && loggedIn;
        if (wanted && !wasRequested) { Retry(); focusOnFirstReady = true; }
        if (!wanted) focusOnFirstReady = false;
        wasRequested = wanted;
        if (wanted && backend == null && !failed)
        {
            try
            {
                services = pi.Create<NativeWindowServices>() ?? throw new InvalidOperationException("Native window services are unavailable");
                backend = CreateBackend(pi, services, nativeName, title, initialSize);
            }
            catch (NativeWindowPendingException ex) { Status = ex.Message; }
            catch (Exception ex) { failed = true; Status = "Native frame unavailable · " + ex.Message; }
        }
        snapshot = backend?.Prepare(wanted) ?? default;
        IsActive = wanted && snapshot.Ready && !snapshot.Hidden && !snapshot.UserClosed;
        ShouldDraw = !(wanted && snapshot.Hidden);
        if (IsActive && !wasActive)
        {
            var root = ImGuiP.FindWindowByName(windowName);
            if (!root.IsNull) { savedPosition = root.Pos; savedSize = root.Size; }
        }
        if (!IsActive && wasActive && ValidSize(savedSize)) restorePending = true;
        wasActive = IsActive;
        if (!failed) Status = wanted ? snapshot.Status ?? "Starting native frame…" : "Normal window";
        if (IsActive && !snapshot.Focused) DropOnlyOurFocus();
    }

    public void ApplyNextWindowLayout()
    {
        if (IsActive)
        {
            ImGui.SetNextWindowPos(ContentPosition);
            ImGui.SetNextWindowSize(ContentSize);
            ImGui.SetNextWindowSizeConstraints(ContentSize, ContentSize);
            if (focusOnFirstReady && snapshot.Focused)
            {
                ImGui.SetNextWindowFocus();
                focusOnFirstReady = false;
            }
        }
        else if (restorePending)
        {
            ImGui.SetNextWindowPos(savedPosition);
            ImGui.SetNextWindowSize(savedSize);
            restorePending = false;
        }
    }

    /// <summary>Returns true only when the owned flat commands were replaced by a native texture.
    /// A failed capture leaves all original lists untouched and closes the native frame.</summary>
    public bool Capture()
    {
        if (disposed || !IsActive || backend == null) return false;
        try
        {
            return NativeWindowCapture.Draw(windowName, ContentPosition, ContentSize, backend.Present);
        }
        catch (Exception ex)
        {
            Status = "Native capture unavailable; normal window restored · " + ex.Message;
            failed = true;
            backend.Fail(Status);
            IsActive = false;
            if (ValidSize(savedSize)) restorePending = true;
            services?.Log.Warning(ex, "Native XivHud window capture stopped; ordinary content remains available");
            return false;
        }
    }

    public void Retry()
    {
        if (disposed) return;
        failed = false;
        if (backend != null && !backend.Retry()) RetireBackend();
    }

    private void DropOnlyOurFocus()
    {
        var root = ImGuiP.FindWindowByName(windowName);
        var context = ImGui.GetCurrentContext();
        if (root.IsNull || context.IsNull || context.NavWindow.IsNull) return;
        if (NativeWindowFocus.OwnsWindow(root, context.NavWindow))
        {
            if (NativeWindowFocus.OwnsWindow(root, context.ActiveIdWindow)) ImGuiP.ClearActiveID();
            ImGuiP.FocusWindow(default);
        }
    }

    [MethodImpl(MethodImplOptions.NoInlining)]
    private static INativeWindowBackend CreateBackend(IDalamudPluginInterface pi, NativeWindowServices services,
        string nativeName, string title, Vector2 size) => new KamiNativeWindowBackend(pi, services, nativeName, title, size);

    internal static bool ValidSize(Vector2 size) => float.IsFinite(size.X) && float.IsFinite(size.Y)
        && size.X >= 32 && size.Y >= 32 && size.X <= 4096 && size.Y <= 4096;

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        RetireBackend();
        IsActive = false;
        Status = "Native frame disposed";
    }

    private void RetireBackend()
    {
        var retiring = backend;
        if (retiring == null) return;
        retiring.Dispose();
        // Keep ownership of earlier asynchronous retirements even after Retry discards
        // their backend. Plugin unload must wait for all of them before disposing pi.
        shutdown.Track(retiring.ShutdownTask);
        backend = null;
    }
}

internal sealed class NativeWindowServices
{
    [PluginService] public IFramework Framework { get; private set; } = null!;
    [PluginService] public ITextureProvider Textures { get; private set; } = null!;
    [PluginService] public IGameGui GameGui { get; private set; } = null!;
    [PluginService] public IPluginLog Log { get; private set; } = null!;
}

internal readonly record struct NativeWindowSnapshot(bool Ready, bool Hidden, bool UserClosed,
    bool AllowInput, bool Focused, Vector2 Position, Vector2 Size, float Scale, string? Status);

internal interface INativeWindowBackend : IDisposable
{
    Task ShutdownTask { get; }
    NativeWindowSnapshot Prepare(bool wanted);
    bool Present(NativeWindowDrawFrame frame);
    void Fail(string reason);
    bool Retry();
}

internal sealed class NativeWindowPendingException(string message) : Exception(message);
