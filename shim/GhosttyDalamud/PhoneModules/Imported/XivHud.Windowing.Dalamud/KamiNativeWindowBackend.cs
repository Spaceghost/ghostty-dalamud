using System.Numerics;
using Dalamud.Bindings.ImGui;
using Dalamud.Interface.Textures.TextureWraps;
using Dalamud.Plugin;
using Dalamud.Plugin.Services;
using FFXIVClientStructs.FFXIV.Component.GUI;
using KamiToolKit;
using KamiToolKit.BaseTypes;
using KamiToolKit.Nodes;
using Lumina.Text.ReadOnly;

namespace XivHud.Windowing.Dalamud;

internal sealed class KamiNativeWindowBackend : INativeWindowBackend
{
    private readonly NativeWindowServices services;
    private readonly KamiRuntime runtime;
    private readonly string name, title;
    private readonly Vector2 size;
    private SurfaceAddon? addon;
    private bool wanted, userClosed, closingByOwner;
    private volatile bool disposed;
    private string? failure;
    private int closedSeen;
    public Task ShutdownTask { get; private set; } = Task.CompletedTask;

    public KamiNativeWindowBackend(IDalamudPluginInterface pi, NativeWindowServices services,
        string name, string title, Vector2 size)
    {
        this.services = services; this.name = name; this.title = title; this.size = size;
        if (typeof(AtkUnitBase).Module.ModuleVersionId != new Guid("7fda2a82-4ca8-49d0-9687-4c8eac011509"))
            throw new NotSupportedException("Native window bindings differ from the verified installed API");
        runtime = KamiRuntime.Acquire(pi, services);
        services.Framework.Update += Tick;
    }

    public unsafe NativeWindowSnapshot Prepare(bool request)
    {
        if (disposed) return default;
        if (!services.Framework.IsInFrameworkUpdateThread)
            return new(false, false, false, false, false, default, default, 1, "Native frame requires the game/UI thread");
        if (wanted != request)
        {
            wanted = request;
            if (request) userClosed = false; // A prior owner-close may still be finalizing.
        }
        var hidden = services.GameGui.GameUiHidden;
        if (failure != null) return new(false, false, false, false, false, default, default, 1, failure);
        if (!runtime.Ready) return new(false, hidden, false, false, false, default, default, 1, runtime.Status);
        if (addon == null || !addon.SetUp) return new(false, hidden, userClosed, false, false, default, default, 1,
            userClosed ? "Native frame closed" : "Opening native frame…");
        AtkUnitBase* unit = addon;
        if (unit == null) return default;
        hidden |= !unit->IsVisible;
        var scale = unit->RootNode != null ? unit->RootNode->ScaleX : unit->Scale;
        var contentSize = addon.ContentSize * scale;
        var pos = new Vector2(unit->X, unit->Y) + addon.ContentStartPosition * scale;
        if (!float.IsFinite(scale) || scale < .1f || scale > 4 || !NativeGameWindowHost.ValidSize(contentSize))
            return new(false, false, false, false, false, default, default, 1, "Native frame dimensions are unavailable");
        pos = new Vector2(MathF.Round(pos.X), MathF.Round(pos.Y));
        contentSize = new Vector2(MathF.Ceiling(contentSize.X), MathF.Ceiling(contentSize.Y));
        var stage = AtkStage.Instance();
        var focused = stage != null && stage->RaptureAtkUnitManager != null && stage->RaptureAtkUnitManager->FocusedAddon == unit;
        var over = stage != null && stage->AtkCollisionManager != null ? stage->AtkCollisionManager->IntersectingAddon : null;
        var allow = !hidden && (over == unit || (over == null && focused));
        return new(true, hidden, userClosed, allow, focused, pos, contentSize, scale, "Native game frame");
    }

    private unsafe void Tick(IFramework _)
    {
        if (disposed || !runtime.Ready) return;
        try
        {
            var hidden = services.GameGui.GameUiHidden;
            if (addon != null && addon.Closes != closedSeen)
            {
                closedSeen = addon.Closes;
                if (!closingByOwner && !addon.LastCloseWasUiHide && !hidden) userClosed = true;
                closingByOwner = false;
            }
            if (!wanted || hidden || failure != null || userClosed)
            {
                if (addon?.SetUp == true) { closingByOwner = true; addon.Close(); }
                return;
            }
            if (addon == null)
            {
                addon = new SurfaceAddon(services.GameGui, size)
                {
                    InternalName = name, Title = new ReadOnlySeString(title.AsSpan()),
                    Subtitle = new ReadOnlySeString("XivHud".AsSpan()), Size = size + new Vector2(16, 48),
                    ContentPadding = Vector2.Zero, RememberClosePosition = true,
                    DisableClamping = false, RespectCloseAll = true,
                };
            }
            AtkUnitBase* unit = addon;
            if (unit == null) addon.Open();
        }
        catch (Exception ex) { Fail("Native frame unavailable · " + ex.Message); services.Log.Warning(ex, "XivHud native game frame stopped"); }
    }

    public unsafe bool Present(NativeWindowDrawFrame frame)
    {
        if (disposed || !wanted || failure != null || addon is not { SetUp: true, Image: { } image }) return false;
        if (!services.Framework.IsInFrameworkUpdateThread) throw new InvalidOperationException("Native capture requires the game/UI thread");
        var requested = frame.Data->DisplaySize;
        if (addon.Texture == null || addon.Texture.Size != requested)
        {
            var texture = services.Textures.CreateDrawListTexture("XivHud native " + name);
            try
            {
                texture.Size = requested;
                texture.ClearColor = Vector4.Zero;
                image.LoadTexture(texture);
                addon.Texture = texture;
            }
            catch { texture.Dispose(); throw; }
        }
        var previouslyPresented = addon.Presented;
        addon.Texture.Draw(new ImDrawDataPtr(frame.Data));
        image.Position = addon.ContentStartPosition;
        image.Size = addon.ContentSize;
        image.TextureCoordinates = Vector2.Zero;
        image.TextureSize = requested;
        addon.Presented = true;
        return previouslyPresented; // First texture reaches the native UI pass on its next frame.
    }

    public void Fail(string reason) { failure = reason; wanted = false; }

    public bool Retry()
    {
        if (disposed || runtime.Failed) return false;
        failure = null;
        userClosed = false;
        return true;
    }

    public void Dispose()
    {
        if (disposed) return;
        disposed = true; wanted = false; closingByOwner = true;
        // Kami requires its async close off the game thread and retains its callback roots
        // until native destruction. The consuming plugin must await this task before its
        // interface/services are disposed; IAsyncDalamudPlugin.DisposeAsync provides
        // that awaited lifetime without blocking framework ticks.
        ShutdownTask = CleanupAsync();
    }

    private async Task CleanupAsync()
    {
        try
        {
            await Task.Run(async () =>
            {
                // A Tick may already have passed its disposed check when an off-thread
                // unload starts. This barrier lets it finish before snapshotting the
                // final addon; otherwise it could create an unowned addon after cleanup.
                var closingAddon = await services.Framework.RunOnFrameworkThread(() =>
                {
                    services.Framework.Update -= Tick;
                    return addon;
                }).ConfigureAwait(false);
                // ConfigureAwait(false) does not force a worker dispatch: completion
                // of the framework barrier can inline this continuation on the game
                // thread. Kami asserts off-main at the entry to DisposeAsync, so
                // schedule that invocation itself after the barrier has completed.
                await Task.Run(async () =>
                {
                    try { if (closingAddon != null) await closingAddon.DisposeAsync(); }
                    finally { await runtime.ReleaseAsync(); }
                }).ConfigureAwait(false);
            }).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            services.Log.Warning(ex, "XivHud native frame cleanup did not finish");
            throw; // ShutdownTask must not report success after a failed retirement.
        }
    }

    private sealed unsafe class SurfaceAddon(IGameGui gameGui, Vector2 contentSize) : NativeAddon
    {
        public ImGuiImageNode? Image;
        public IDrawListTextureWrap? Texture;
        public bool SetUp, Presented, LastCloseWasUiHide;
        public int Closes;

        protected override void OnSetup(AtkUnitBase* addon, Span<AtkValue> values)
        {
            SetWindowSize(Size + contentSize - ContentSize);
            Image = new ImGuiImageNode { Position = ContentStartPosition, Size = ContentSize,
                WrapMode = KamiToolKit.Enums.WrapMode.Stretch, IsVisible = true };
            AddNode(Image);
            SetUp = true; Presented = false; LastCloseWasUiHide = false;
        }
        protected override void OnHide(AtkUnitBase* addon) => LastCloseWasUiHide = gameGui.GameUiHidden;
        protected override void OnFinalize(AtkUnitBase* addon)
        {
            LastCloseWasUiHide |= gameGui.GameUiHidden;
            SetUp = Presented = false; Image = null; Texture = null; Closes++;
        }
    }
}

/// <summary>One owned Kami lifetime per plugin load context; several module windows can share it.
/// Never initializes or disposes a toolkit that some other component already owns.</summary>
internal sealed class KamiRuntime
{
    private static readonly object Gate = new();
    private static KamiRuntime? current;
    private static IDalamudPluginInterface? lastOwner;
    private readonly IDalamudPluginInterface pi;
    private readonly NativeWindowServices services;
    private readonly Task initialization;
    private int references;
    private bool retiring;

    private KamiRuntime(IDalamudPluginInterface pi, NativeWindowServices services)
    {
        this.pi = pi; this.services = services;
        if (KamiToolKitLibrary.PluginInterface != null && !ReferenceEquals(lastOwner, pi))
            throw new InvalidOperationException("This plugin already has a different Kami runtime owner");
        lastOwner = pi;
        var level = services.Log.MinimumLogLevel;
        try { initialization = KamiToolKitLibrary.InitializeAsync(pi, "XivHud"); }
        finally
        {
            // Once initialization has started, a logging-setting failure must not abandon
            // its ownership before Acquire can publish the runtime and later retire it.
            try { services.Log.MinimumLogLevel = level; }
            catch { }
        }
    }

    public bool Ready => initialization.IsCompletedSuccessfully;
    public bool Failed => initialization.IsFaulted || initialization.IsCanceled;
    public string Status => Failed ? "Native toolkit initialization failed · " + initialization.Exception?.GetBaseException().Message : "Starting native toolkit…";
    public static KamiRuntime Acquire(IDalamudPluginInterface pi, NativeWindowServices services)
    {
        lock (Gate)
        {
            if (current is { retiring: true }) throw new NativeWindowPendingException("Previous native toolkit is still closing…");
            current ??= new KamiRuntime(pi, services);
            if (!ReferenceEquals(current.pi, pi)) throw new InvalidOperationException("Native runtime belongs to another plugin");
            current.references++;
            return current;
        }
    }

    public async Task ReleaseAsync()
    {
        lock (Gate)
        {
            if (--references != 0) return;
            retiring = true;
        }
        try
        {
            try { await initialization.ConfigureAwait(false); }
            catch (Exception ex) { services.Log.Warning(ex, "XivHud native toolkit initialization failed"); }
            await KamiToolKitLibrary.DisposeAsync().ConfigureAwait(false);
        }
        finally { lock (Gate) if (ReferenceEquals(current, this)) current = null; }
    }
}
