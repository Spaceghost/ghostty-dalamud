using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;
using Dalamud.Game.ClientState.Conditions;
using Dalamud.Hooking;
using Dalamud.Plugin;
using Dalamud.Plugin.Ipc;
using Dalamud.Plugin.Services;
using FFXIVClientStructs.FFXIV.Client.System.Input;
using XivHud.Core;

namespace XivHud.Plugin;

/// <summary>One pad-poll owner for the XivHud family. Features renew only while
/// their own UI is focused. Never enables global Dalamud/ImGui gamepad mode.</summary>
public sealed unsafe class ControllerBroker : IDisposable
{
    private const string Prefix = "XivHud.v1.Controller.";
    private static readonly Guid VerifiedStructs = new("7fda2a82-4ca8-49d0-9687-4c8eac011509");
    private static readonly Guid VerifiedDalamud = new("9a6f3e4f-c2f0-46f4-b211-7013dde20a8b");
    private readonly object gate = new();
    private readonly ControllerFocusLease lease = new(NewSession());
    private readonly IGamepadState gamepad;
    private readonly IClientState client;
    private readonly ICondition condition;
    private readonly IPluginLog log;
    private readonly ICallGateProvider<string, ulong, bool> renew, release;
    private readonly ICallGateProvider<string, ulong, string> read;
    private readonly ICallGateProvider<string> getStatus;
    private Hook<PadDevice.Delegates.Update>? hook;
    private bool disposed, failed, registeredRenew, registeredRelease, registeredRead, registeredStatus, deviceAvailable;
    private int activeCallbacks, lastIndex = -1;
    private nint lastDevice;
    private Guid lastGuid;
    private ulong source;
    private long capturedPolls;
    private string status = "Controller input is available to the game.";
    private static double Now => Stopwatch.GetTimestamp() / (double)Stopwatch.Frequency;
    private static ulong NewSession()
    {
        var value = BitConverter.ToUInt64(Guid.NewGuid().ToByteArray());
        return value == 0 ? 1 : value;
    }

    public ControllerBroker(IDalamudPluginInterface pi, IGameInteropProvider interop,
        IGamepadState gamepad, IClientState client, ICondition condition, IPluginLog log)
    {
        this.gamepad = gamepad; this.client = client; this.condition = condition; this.log = log;
        renew = pi.GetIpcProvider<string, ulong, bool>(Prefix + "Renew");
        release = pi.GetIpcProvider<string, ulong, bool>(Prefix + "Release");
        read = pi.GetIpcProvider<string, ulong, string>(Prefix + "Read");
        getStatus = pi.GetIpcProvider<string>(Prefix + "Status");
        try
        {
            renew.RegisterFunc(Renew); registeredRenew = true;
            release.RegisterFunc(Release); registeredRelease = true;
            read.RegisterFunc(Read); registeredRead = true;
            getStatus.RegisterFunc(() => Status); registeredStatus = true;
            // The exact installed API was inspected: Dalamud itself hooks this
            // virtual update original-first. Fail open when that ABI changes.
            if (typeof(PadDevice).Module.ModuleVersionId != VerifiedStructs
                || typeof(IGamepadState).Module.ModuleVersionId != VerifiedDalamud
                || sizeof(GamepadInputData) != 588
                || Marshal.OffsetOf<PadDevice>(nameof(PadDevice.GamepadInputData)).ToInt32() != 120)
                throw new NotSupportedException("Controller bindings differ from the verified installed API.");
            var table = PadDevice.StaticVirtualTablePointer;
            if (table == null || table->Update == null)
                throw new NotSupportedException("The native controller update is unavailable.");
            hook = interop.HookFromAddress<PadDevice.Delegates.Update>((nint)table->Update, Poll);
            hook.Enable();
            status = "Controller broker ready; no focused feature owns input.";
            log.Information("XivHud controller broker ready; scoped focus leases only, global gamepad mode unchanged.");
        }
        catch (Exception ex)
        {
            lock (gate)
            {
                failed = true; lease.Invalidate(); status = "Controller broker unavailable; game input preserved.";
                hook?.Disable();
                while (activeCallbacks != 0) Monitor.Wait(gate);
                hook?.Dispose(); // Retain reference for late OriginalDisposeSafe continuations.
            }
            log.Warning(ex, "XivHud controller broker was not enabled; game input remains available.");
        }
    }

    public string Status
    {
        get
        {
            lock (gate)
            {
                if (disposed || failed) return "Controller support is unavailable here. Native game controls remain available.";
                if (gamepad.EnableGamepadNav) return "Another controller navigation mode is active.";
                if (!client.IsLoggedIn) return "Controller controls are available after logging in.";
                if (!deviceAvailable) return "No controller input detected. Enable a gamepad in FFXIV's Gamepad Settings.";
                if (!Eligible()) return "Controller controls will resume after the current game scene.";
                return "Controller ready. Focus this window to use it.";
            }
        }
    }
    public string Diagnostic { get { lock (gate) return $"{status} Captured polls: {capturedPolls}."; } }

    public bool Renew(string owner, ulong generation)
    {
        lock (gate)
        {
            if (!Eligible() || !deviceAvailable) { lease.Invalidate(); return false; }
            return lease.Renew(owner, generation, Now);
        }
    }

    public bool Release(string owner, ulong generation)
    {
        lock (gate) return !disposed && lease.Release(owner, generation, Now);
    }

    public string Read(string owner, ulong generation)
    {
        var frame = ReadSnapshot(owner, generation);
        return frame is { } value ? JsonSerializer.Serialize(value) : "";
    }

    public ControllerFrame? ReadSnapshot(string owner, ulong generation)
    {
        lock (gate)
        {
            if (!Eligible()) { lease.Invalidate(); return null; }
            return lease.Read(owner, generation, Now);
        }
    }

    private bool Eligible() => !disposed && !failed && hook is { IsEnabled: true }
        && !gamepad.EnableGamepadNav && client.IsLoggedIn
        && !condition[ConditionFlag.BetweenAreas] && !condition[ConditionFlag.BetweenAreas51]
        && !condition[ConditionFlag.WatchingCutscene] && !condition[ConditionFlag.WatchingCutscene78];

    private void Poll(PadDevice* pad)
    {
        PadDevice.Delegates.Update original;
        lock (gate) { original = hook!.OriginalDisposeSafe; activeCallbacks++; }
        try
        {
            original(pad); // Exactly once, including shutdown/failure paths.
            lock (gate)
            {
                if (!Eligible() || pad == null) { if (pad == null) deviceAvailable = false; lease.Invalidate(); return; }
                var raw = pad->GamepadInputData; // Immutable local read before any filtering.
                var index = pad->ActiveGamepadDeviceIndex;
                var count = pad->GamepadDevices.LongCount;
                if (!pad->Settings.PadAvailable || index < 0 || count is <1 or >16 || index >= count)
                { deviceAvailable = false; lease.Invalidate(); return; }
                var guid = pad->GamepadDevices[index].DeviceInfo.Instance;
                if (lastDevice != (nint)pad || lastIndex != index || lastGuid != guid)
                {
                    lastDevice = (nint)pad; lastIndex = index; lastGuid = guid;
                    source++; if (source == 0) source++;
                }
                var snapshot = new ControllerSample(source, (uint)raw.Buttons,
                    raw.LeftStickX / 100f, -raw.LeftStickY / 100f,
                    raw.RightStickX / 100f, -raw.RightStickY / 100f,
                    raw.PSButton == 0 && raw.MuteButton == 0);
                deviceAvailable = snapshot.Valid;
                var filter = lease.Poll(snapshot, true, Now);
                if (filter.All || filter.Buttons != 0)
                {
                    Filter(ref pad->GamepadInputData, filter);
                    capturedPolls++;
                }
            }
        }
        catch (Exception ex)
        {
            bool report;
            lock (gate) { report = !failed; failed = true; lease.Invalidate(); status = "Controller capture stopped; game input preserved."; }
            if (report) try { log.Error(ex, "XivHud controller capture failed open."); } catch { }
        }
        finally
        {
            lock (gate) { activeCallbacks--; Monitor.PulseAll(gate); }
        }
    }

    private static void Filter(ref GamepadInputData x, ControllerFilter filter)
    {
        var mask = (GamepadButtonsFlags)filter.Buttons;
        if (filter.All)
        {
            mask = (GamepadButtonsFlags)0xFFFF;
            x.LeftStickX = x.LeftStickY = x.RightStickX = x.RightStickY = 0;
            x.LeftStickLeft = x.LeftStickRight = x.LeftStickUp = x.LeftStickDown = 0;
            x.RightStickLeft = x.RightStickRight = x.RightStickUp = x.RightStickDown = 0;
            x.PSButton = x.MuteButton = 0;
        }
        x.Buttons &= ~mask; x.ButtonsPressed &= ~mask;
        x.ButtonsReleased &= ~mask; x.ButtonsRepeat &= ~mask;
        if ((mask & GamepadButtonsFlags.Square) != 0) x.Square = 0;
        if ((mask & GamepadButtonsFlags.Cross) != 0) x.Cross = 0;
        if ((mask & GamepadButtonsFlags.Circle) != 0) x.Circle = 0;
        if ((mask & GamepadButtonsFlags.Triangle) != 0) x.Triangle = 0;
        if ((mask & GamepadButtonsFlags.L1) != 0) x.L1 = 0;
        if ((mask & GamepadButtonsFlags.L2) != 0) x.L2 = 0;
        if ((mask & GamepadButtonsFlags.L3) != 0) x.L3 = 0;
        if ((mask & GamepadButtonsFlags.R1) != 0) x.R1 = 0;
        if ((mask & GamepadButtonsFlags.R2) != 0) x.R2 = 0;
        if ((mask & GamepadButtonsFlags.R3) != 0) x.R3 = 0;
        if ((mask & GamepadButtonsFlags.Select) != 0) x.Select = 0;
        if ((mask & GamepadButtonsFlags.Start) != 0) x.Start = 0;
        if ((mask & GamepadButtonsFlags.DPadUp) != 0) x.DPadUp = 0;
        if ((mask & GamepadButtonsFlags.DPadDown) != 0) x.DPadDown = 0;
        if ((mask & GamepadButtonsFlags.DPadLeft) != 0) x.DPadLeft = 0;
        if ((mask & GamepadButtonsFlags.DPadRight) != 0) x.DPadRight = 0;
    }

    public void Dispose()
    {
        Hook<PadDevice.Delegates.Update>? old;
        lock (gate)
        {
            if (disposed) return;
            disposed = true; lease.Dispose(); old = hook;
        }
        if (registeredRenew) renew.UnregisterFunc();
        if (registeredRelease) release.UnregisterFunc();
        if (registeredRead) read.UnregisterFunc();
        if (registeredStatus) getStatus.UnregisterFunc();
        lock (gate)
        {
            old?.Disable();
            while (activeCallbacks != 0) Monitor.Wait(gate); // Releases gate while waiting.
            old?.Dispose();
        }
    }
}
