using System.Diagnostics;
using System.Runtime.InteropServices;
using Dalamud.Hooking;
using Dalamud.Plugin.Services;
using FFXIVClientStructs.FFXIV.Client.System.Input;

namespace XivSpell;

// Focused capture only. The game's controller mode and global ImGui settings
// are untouched; releasing the view returns native movement immediately.
internal sealed unsafe class GrimoirePad : IDisposable
{
    private readonly object gate = new();
    private readonly GrimoirePadLease lease = new();
    private readonly Hook<PadDevice.Delegates.Update> hook;
    private bool disposed, enabled, chordHeld;
    private int opened, activeCallbacks;
    private static double Now => Stopwatch.GetTimestamp() / (double)Stopwatch.Frequency;
    internal bool TakeOpen() => Interlocked.Exchange(ref opened, 0) != 0;
    internal GrimoirePad(IGameInteropProvider interop)
    {
        if (sizeof(GamepadInputData) != 588 || Marshal.OffsetOf<PadDevice>(nameof(PadDevice.GamepadInputData)).ToInt32() != 120)
            throw new NotSupportedException("Controller layout differs from installed bindings");
        hook = interop.HookFromAddress<PadDevice.Delegates.Update>((nint)PadDevice.StaticVirtualTablePointer->Update, Poll);
        hook.Enable();
    }
    internal GrimoirePadFrame? Read(bool available, bool focus)
    {
        lock (gate) {
            enabled = available;
            if (!available || !focus) { lease.Release("XivHud.Grimoire", 1, Now); return null; }
            lease.Renew("XivHud.Grimoire", 1, Now);
            return lease.Read("XivHud.Grimoire", 1, Now);
        }
    }
    private void Poll(PadDevice* pad)
    {
        PadDevice.Delegates.Update original;
        lock (gate) { original = hook.OriginalDisposeSafe; activeCallbacks++; }
        try {
            original(pad);
            lock (gate) {
                if (disposed || !enabled || pad == null || !pad->Settings.PadAvailable) { lease.Invalidate(); return; }
                var raw = pad->GamepadInputData;
                var chord = (raw.Buttons & (GamepadButtonsFlags.L3 | GamepadButtonsFlags.R3)) == (GamepadButtonsFlags.L3 | GamepadButtonsFlags.R3);
                if (chord && !chordHeld) Interlocked.Exchange(ref opened, 1);
                chordHeld = chord;
                if (chord) Filter(ref pad->GamepadInputData, (uint)(GamepadButtonsFlags.L3 | GamepadButtonsFlags.R3));
                var sample = new GrimoirePadSample(1, (uint)raw.Buttons, raw.LeftStickX / 100f, -raw.LeftStickY / 100f,
                    raw.RightStickX / 100f, -raw.RightStickY / 100f, raw.PSButton == 0 && raw.MuteButton == 0);
                var filter = lease.Poll(sample, true, Now);
                if (filter.All) {
                    ref var input = ref pad->GamepadInputData;
                    input.LeftStickX = input.LeftStickY = input.RightStickX = input.RightStickY = 0;
                    input.LeftStickLeft = input.LeftStickRight = input.LeftStickUp = input.LeftStickDown = 0;
                    input.RightStickLeft = input.RightStickRight = input.RightStickUp = input.RightStickDown = 0;
                    input.PSButton = input.MuteButton = 0;
                    Filter(ref input, 0xFFFF);
                } else if (filter.Buttons != 0) Filter(ref pad->GamepadInputData, filter.Buttons);
            }
        } catch { lock (gate) { enabled = false; lease.Invalidate(); } }
        finally { lock (gate) { activeCallbacks--; Monitor.PulseAll(gate); } }
    }
    private static void Filter(ref GamepadInputData x, uint buttons)
    {
        var mask = (GamepadButtonsFlags)buttons;
        x.Buttons &= ~mask; x.ButtonsPressed &= ~mask; x.ButtonsReleased &= ~mask; x.ButtonsRepeat &= ~mask;
        if ((mask & GamepadButtonsFlags.Cross) != 0) x.Cross = 0;
        if ((mask & GamepadButtonsFlags.Circle) != 0) x.Circle = 0;
        if ((mask & GamepadButtonsFlags.Square) != 0) x.Square = 0;
        if ((mask & GamepadButtonsFlags.Triangle) != 0) x.Triangle = 0;
        if ((mask & GamepadButtonsFlags.L1) != 0) x.L1 = 0;
        if ((mask & GamepadButtonsFlags.R1) != 0) x.R1 = 0;
        if ((mask & GamepadButtonsFlags.L2) != 0) x.L2 = 0;
        if ((mask & GamepadButtonsFlags.R2) != 0) x.R2 = 0;
        if ((mask & GamepadButtonsFlags.L3) != 0) x.L3 = 0;
        if ((mask & GamepadButtonsFlags.R3) != 0) x.R3 = 0;
        if ((mask & GamepadButtonsFlags.Start) != 0) x.Start = 0;
        if ((mask & GamepadButtonsFlags.Select) != 0) x.Select = 0;
        if ((mask & GamepadButtonsFlags.DPadUp) != 0) x.DPadUp = 0;
        if ((mask & GamepadButtonsFlags.DPadDown) != 0) x.DPadDown = 0;
        if ((mask & GamepadButtonsFlags.DPadLeft) != 0) x.DPadLeft = 0;
        if ((mask & GamepadButtonsFlags.DPadRight) != 0) x.DPadRight = 0;
    }
    public void Dispose()
    {
        lock (gate) { if (disposed) return; disposed = true; enabled = false; lease.Dispose(); }
        hook.Disable();
        lock (gate) { while (activeCallbacks != 0) Monitor.Wait(gate); hook.Dispose(); }
    }
}
