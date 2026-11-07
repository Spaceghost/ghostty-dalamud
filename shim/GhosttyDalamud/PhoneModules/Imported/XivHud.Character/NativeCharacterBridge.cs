using Dalamud.Game.Addon.Lifecycle;
using Dalamud.Game.Addon.Lifecycle.AddonArgTypes;
using Dalamud.Hooking;
using Dalamud.Plugin.Services;
using FFXIVClientStructs.FFXIV.Client.UI;
using FFXIVClientStructs.FFXIV.Client.UI.Agent;

namespace XivHud.Character;

/// <summary>Uses the game's Character action (including its existing key binding), never raw key state.</summary>
public sealed unsafe class NativeCharacterBridge : IDisposable
{
    private const string AddonName = "Character";
    private static readonly AddonEvent[] Events =
        [AddonEvent.PostSetup, AddonEvent.PostOpen, AddonEvent.PostShow,
         AddonEvent.PostRequestedUpdate, AddonEvent.PostRefresh,
         AddonEvent.PostHide, AddonEvent.PostClose, AddonEvent.PreFinalize];
    private readonly IAddonLifecycle lifecycle;
    private readonly IFramework framework;
    private readonly IPluginLog log;
    private readonly IGameInteropProvider interop;
    private readonly object hookGate = new();
    private Hook<UIModule.Delegates.ExecuteMainCommand>? commandHook;
    private int commandCallbacks;
    private bool hookFailed;
    private bool commandHookReady;
    private readonly object requestGate = new();
    private Request? request;
    private ushort pendingAddon;
    private nint pendingAddress;
    private bool nativeBypass;
    private bool bypassSeenActive;
    private bool issuingNativeRequest;
    private DateTime bypassDeadline;
    private bool disposed;
    private string lastLifecycle = "none";
    private string lastAdoption = "none";
    private int adoptions;
    private NativeState lastNative;

    private enum RequestKind { Open, Armoury, GameCommand }
    private readonly record struct Request(RequestKind Kind);
    private readonly record struct NativeState(bool Active, uint Addon, int Status, bool Visible);

    public NativeCharacterBridge(IAddonLifecycle lifecycle, IFramework framework, IPluginLog log, IGameInteropProvider interop)
    {
        this.lifecycle = lifecycle;
        this.framework = framework;
        this.log = log;
        this.interop = interop;
        try
        {
            // The name narrows delivery; the live agent's addon id still decides identity.
            foreach (var type in Events) lifecycle.RegisterListener(type, AddonName, OnAddon);
            framework.Update += Update;
        }
        catch
        {
            lifecycle.UnregisterListener(OnAddon);
            throw;
        }
    }

    /// <summary>Enable only after the replacement window and its handler are ready.</summary>
    public bool AdoptNativeOpens { get; set; }
    public event Action? ToggleRequested;
    public event Action? MainCommandToggleRequested;
    public Func<bool>? CanAdopt { get; set; }
    public string? LastError { get; private set; }
    public string BridgeState => $"hook={commandHookReady}; native={lastNative}; pending={pendingAddon}; bypass={nativeBypass}; " +
        $"adoptions={adoptions}; lifecycle={lastLifecycle}; lastAdoption={lastAdoption}";

    /// <summary>Runs the game's own Character menu command, also used by its configured binding.
    /// This is an adoption diagnostic/action, unlike the explicit original-window fallback.</summary>
    public void InvokeGameCharacter() => Enqueue(new Request(RequestKind.GameCommand));

    /// <summary>Explicit fallback. Remains native until the user closes that window.</summary>
    public void OpenNative() => Enqueue(new Request(RequestKind.Open));

    /// <summary>The game's Armoury Chest main command; it passes through this module's own hook.</summary>
    public void OpenArmoury() => Enqueue(new Request(RequestKind.Armoury));

    private void Enqueue(Request value)
    {
        lock (requestGate)
            if (!disposed) request = value;
    }

    private void OnAddon(AddonEvent type, AddonArgs args)
    {
        if (disposed || args.Addon.IsNull) return;
        var agent = AgentStatus.Instance();
        if (agent == null) return;
        var addonId = agent->GetAddonId();
        // The live agent's addon identity is authoritative; no guessed node IDs. Widen before comparing.
        if (addonId is 0 or > ushort.MaxValue || args.Addon.Id != addonId) return;
        lastLifecycle = $"{type}/{args.AddonName}/{addonId}/visible={args.Addon.IsVisible}";
        if (type is AddonEvent.PostHide or AddonEvent.PostClose or AddonEvent.PreFinalize)
        {
            pendingAddon = 0;
            pendingAddress = 0;
            // Retiring a hidden cached instance while issuing the explicit fallback
            // must not cancel the native request being issued now.
            if (!issuingNativeRequest)
            {
                nativeBypass = false;
                bypassSeenActive = false;
            }
            return;
        }
        if (!AdoptNativeOpens || nativeBypass || ToggleRequested == null) return;
        // A cached window may be populated by a requested/refresh update without a new
        // setup/show call. Such an update is an open candidate only when actually visible.
        if (type is AddonEvent.PostRequestedUpdate or AddonEvent.PostRefresh && !args.Addon.IsVisible) return;
        pendingAddon = (ushort)addonId;
        pendingAddress = args.Addon.Address;
    }

    private void Update(IFramework _)
    {
        if (disposed) return;
        EnsureCommandHook();
        Request? next;
        lock (requestGate) { next = request; request = null; }
        try
        {
            if (next is { Kind: RequestKind.Armoury })
            {
                var module = UIModule.Instance();
                if (module != null && module->IsMainCommandUnlocked(CharacterMath.MainCommandArmoury))
                    // MainCommand row 25, verified Armoury Chest in the installed sheet. Our hook forwards it untouched.
                    module->ExecuteMainCommand(CharacterMath.MainCommandArmoury);
                else LastError = "The Armoury Chest is not available right now.";
                next = null;
            }
            var agent = AgentStatus.Instance();
            if (agent == null)
            {
                pendingAddon = 0;
                pendingAddress = 0;
                nativeBypass = false;
                bypassSeenActive = false;
                return;
            }
            lastNative = ReadState(agent);
            if (next is { Kind: RequestKind.GameCommand })
            {
                var module = UIModule.Instance();
                if (module != null && module->IsMainCommandUnlocked(CharacterMath.MainCommandCharacter))
                {
                    var before = ReadState(agent);
                    module->ExecuteMainCommand(CharacterMath.MainCommandCharacter); // MainCommand row 2, verified Character.
                    log.Information("Character game command 2: before={Before}; after={After}", before, ReadState(agent));
                }
                next = null;
            }
            if (next is { Kind: RequestKind.Open })
            {
                // Set before Show: it may synchronously emit lifecycle events.
                nativeBypass = true;
                bypassSeenActive = false;
                pendingAddon = 0;
                pendingAddress = 0;
                LastError = null;
                // The Character addon also prepares its 3D view: allow it longer to appear.
                bypassDeadline = DateTime.UtcNow.AddSeconds(6);
                issuingNativeRequest = true;
                try
                {
                    if (agent->IsAgentActive() && agent->IsAddonShown()) agent->FocusAddon();
                    else
                    {
                        // Close an existing hidden instance first, then take the inactive Show path
                        // (through Dalamud's agent thunk, which calls the original Show).
                        if (agent->IsAgentActive()) agent->Hide();
                        agent->Show();
                    }
                }
                finally
                {
                    issuingNativeRequest = false;
                }
            }
            var active = agent->IsAgentActive();
            if (nativeBypass)
            {
                var visible = ReadState(agent).Visible && agent->IsAddonShown();
                bypassSeenActive |= visible;
                if (!CharacterCommandPolicy.KeepNativeBypass(visible, bypassSeenActive, DateTime.UtcNow >= bypassDeadline))
                {
                    nativeBypass = false;
                    bypassSeenActive = false;
                }
                return;
            }
            if (!AdoptNativeOpens || ToggleRequested == null)
            {
                pendingAddon = 0;
                pendingAddress = 0;
                return;
            }
            if (pendingAddon == 0 || !active || !agent->IsAddonShown()) return;
            var addonId = agent->GetAddonId();
            if (addonId != pendingAddon)
            {
                pendingAddon = 0;
                pendingAddress = 0;
                return;
            }
            // Identity is revalidated on the framework thread. Never dereference the queued addon address.
            var ui = agent->UIModuleInterface;
            var atk = ui == null ? null : ui->GetRaptureAtkModule();
            var addon = atk == null ? null : atk->RaptureAtkUnitManager.GetAddonById((ushort)addonId);
            if (addon == null || (nint)addon != pendingAddress)
            {
                pendingAddon = 0;
                pendingAddress = 0;
                return;
            }
            pendingAddon = 0;
            pendingAddress = 0;
            if (CanAdopt?.Invoke() == false) return;
            // If the replacement handler fails, leave the real window visible as the fallback.
            ToggleRequested.Invoke();
            var beforeHide = ReadState(agent);
            agent->Hide();
            lastNative = ReadState(agent);
            adoptions++;
            lastAdoption = $"{beforeHide} -> {lastNative}";
            log.Information("Character window adopted: {State}", lastAdoption);
        }
        catch (Exception ex)
        {
            pendingAddon = 0;
            pendingAddress = 0;
            LastError = "The original character window is available while the replacement recovers.";
            log.Error(ex, "Character native bridge action failed; native fallback retained.");
        }
    }

    private static NativeState ReadState(AgentStatus* agent)
    {
        var id = agent->GetAddonId();
        var ui = agent->UIModuleInterface;
        var atk = ui == null ? null : ui->GetRaptureAtkModule();
        var addon = atk == null || id is 0 or > ushort.MaxValue ? null : atk->RaptureAtkUnitManager.GetAddonById((ushort)id);
        return new NativeState(agent->IsAgentActive(), id, (int)agent->GetAddonStatus(), addon != null && addon->IsVisible);
    }

    private void EnsureCommandHook()
    {
        lock (hookGate)
        {
            if (disposed) return;
            if (commandHook != null || hookFailed) return;
            var module = UIModule.Instance();
            if (module == null || module->VirtualTable == null || module->VirtualTable->ExecuteMainCommand == null) return;
            try
            {
                // Matched generated ABI: delegate void ExecuteMainCommand(UIModule*, uint),
                // vtable slot 206. Dalamud does not swap the UIModule vtable, so this is the
                // game function. Agent vtables are swapped and never hooked here.
                commandHook = interop.HookFromAddress<UIModule.Delegates.ExecuteMainCommand>(
                    (nint)module->VirtualTable->ExecuteMainCommand, OnMainCommand);
                commandHook.Enable();
                commandHookReady = true;
                log.Information("Character native main-command interception ready (Character command 2).");
            }
            catch (Exception ex)
            {
                commandHook?.Disable();
                while (commandCallbacks != 0) Monitor.Wait(hookGate);
                commandHook?.Dispose();
                commandHookReady = false;
                hookFailed = true;
                log.Warning(ex, "Character command interception unavailable; the native window and addon adoption remain available.");
            }
        }
    }

    private void OnMainCommand(UIModule* module, uint command)
    {
        UIModule.Delegates.ExecuteMainCommand original;
        lock (hookGate)
        {
            // Hook retirement and choosing its continuation are atomic. A callback
            // already in the native chain can arrive after Disable/Dispose.
            original = commandHook!.OriginalDisposeSafe;
            commandCallbacks++;
        }
        try
        {
            // Other modules (Journal's command 4) hook this same function: every
            // command this module does not own is forwarded unchanged.
            if (disposed || !commandHookReady || command != CharacterMath.MainCommandCharacter ||
                !framework.IsInFrameworkUpdateThread || module != UIModule.Instance())
            {
                original(module, command);
                return;
            }
            try
            {
                var agent = AgentStatus.Instance();
                if (agent != null)
                {
                    var state = ReadState(agent);
                    var bypass = nativeBypass && CharacterCommandPolicy.KeepNativeBypass(state.Visible,
                        bypassSeenActive, DateTime.UtcNow >= bypassDeadline);
                    var ready = MainCommandToggleRequested != null && CanAdopt?.Invoke() == true;
                    if (CharacterCommandPolicy.CanReplace(command, true, AdoptNativeOpens, ready, bypass, state.Visible,
                            module->IsMainCommandUnlocked(CharacterMath.MainCommandCharacter) && agent->IsActivatable()))
                    {
                        MainCommandToggleRequested!.Invoke();
                        nativeBypass = false;
                        bypassSeenActive = false;
                        pendingAddon = 0;
                        pendingAddress = 0;
                        // Retire a hidden, cached native instance so later explicit native
                        // fallback starts from the game's real inactive state.
                        if (state.Active) agent->Hide();
                        lastNative = ReadState(agent);
                        log.Information("Character native command 2 toggled the record; before={Before}; after={After}", state, lastNative);
                        return;
                    }
                }
            }
            catch (Exception ex)
            {
                log.Warning(ex, "Character command replacement failed; forwarding the native Character command.");
            }
            original(module, command);
        }
        finally
        {
            lock (hookGate)
            {
                commandCallbacks--;
                if (commandCallbacks == 0) Monitor.PulseAll(hookGate);
            }
        }
    }

    public void Dispose()
    {
        lock (requestGate)
        {
            if (disposed) return;
            disposed = true;
            request = null;
        }
        framework.Update -= Update;
        lifecycle.UnregisterListener(OnAddon);
        // The handler only changes managed window state and cannot request plugin disposal.
        // Disable first, then keep the captured Original trampoline alive for any callbacks
        // already running before releasing the hook.
        lock (hookGate)
        {
            commandHook?.Disable();
            while (commandCallbacks != 0) Monitor.Wait(hookGate);
            commandHook?.Dispose();
            commandHookReady = false;
        }
        ToggleRequested = null;
        MainCommandToggleRequested = null;
        CanAdopt = null;
    }
}
