using System.Diagnostics;
using System.Text.Json;
using Dalamud.Plugin;
using Dalamud.Plugin.Ipc;

namespace XivHud.Journal;

/// <summary>Optional XivHud broker lease, renewed only by a freshly focused Journal draw.</summary>
internal sealed class JournalControllerClient : IDisposable
{
    private const string Owner = "XivHud.Journal";
    private readonly ICallGateSubscriber<string, ulong, bool> renew, release;
    private readonly ICallGateSubscriber<string, ulong, string> read;
    private readonly ICallGateSubscriber<string> status;
    private readonly JournalControllerInput input = new();
    private readonly Configuration config;
    private ulong generation;
    private bool focused;
    private double retryAt;
    internal bool IsAvailable { get; private set; }
    internal string Phase { get; private set; } = "Unavailable";
    internal string Status { get; private set; } = "Enable XivHud to use controller navigation.";
    private double nextStatusRead;

    internal JournalControllerClient(IDalamudPluginInterface pi, Configuration config)
    {
        this.config = config;
        renew = pi.GetIpcSubscriber<string, ulong, bool>("XivHud.v1.Controller.Renew");
        release = pi.GetIpcSubscriber<string, ulong, bool>("XivHud.v1.Controller.Release");
        read = pi.GetIpcSubscriber<string, ulong, string>("XivHud.v1.Controller.Read");
        status = pi.GetIpcSubscriber<string>("XivHud.v1.Controller.Status");
    }

    internal IReadOnlyList<JournalControllerIntent> Poll(bool hasFocus)
    {
        if (!hasFocus) { Release(); return []; }
        var now = Stopwatch.GetTimestamp() / (double)Stopwatch.Frequency;
        if (now < retryAt) return [];
        if (!focused)
        {
            generation = unchecked((ulong)Stopwatch.GetTimestamp());
            if (generation == 0) generation = 1;
            input.Reset(); focused = true;
        }
        try
        {
            if (!renew.InvokeFunc(Owner, generation))
            {
                input.Reset(); Phase = "Waiting"; IsAvailable = false;
                if (now >= nextStatusRead)
                {
                    nextStatusRead = now + .5;
                    try { Status = status.InvokeFunc(); } catch { Status = "Controller navigation is waiting for the game and a connected controller."; }
                }
                return [];
            }
            var json = read.InvokeFunc(Owner, generation);
            if (string.IsNullOrWhiteSpace(json))
            {
                input.Reset(); IsAvailable = false; Phase = "Waiting";
                Status = "Waiting for a fresh controller frame.";
                return [];
            }
            if (json.Length > 4096) { Release(); return []; }
            var frame = JsonSerializer.Deserialize<JournalPadFrame>(json);
            if (frame == null || frame.Version != 1) { Release(); return []; }
            IsAvailable = true; Phase = frame.Phase;
            Status = frame.Phase switch
            {
                "Active" => "Controller ready. Input stays with this journal while it has focus.",
                "WaitingForNeutral" => "Release the buttons and sticks to start navigating this journal.",
                "Draining" => "Release the buttons and sticks to return to the game.",
                _ => "Controller navigation is waiting for focus.",
            };
            return input.Read(frame, now, config.SwapConfirmBack);
        }
        catch
        {
            Release(); IsAvailable = false; Phase = "Unavailable"; Status = "Enable XivHud to use controller navigation."; retryAt = now + 1;
            return [];
        }
    }

    internal void Release()
    {
        if (focused)
        {
            try { release.InvokeFunc(Owner, generation); } catch { /* Optional provider may already be unloaded. */ }
        }
        focused = false; input.Reset();
        if (IsAvailable) { Phase = "Unfocused"; Status = "Focus this journal to use controller navigation."; }
    }
    public void Dispose() => Release();
}
