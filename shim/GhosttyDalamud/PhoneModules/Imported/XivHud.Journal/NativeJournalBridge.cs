using Dalamud.Game.Addon.Lifecycle;
using Dalamud.Game.Addon.Lifecycle.AddonArgTypes;
using Dalamud.Hooking;
using Dalamud.Plugin.Services;
using FFXIVClientStructs.FFXIV.Client.UI;
using FFXIVClientStructs.FFXIV.Client.UI.Agent;

namespace XivHud.Journal;

/// <summary>Uses the game's Journal action (including its existing key binding), never raw key state.</summary>
public sealed unsafe class NativeJournalBridge : IDisposable
{
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
    private uint pendingMap;
    private DateTime mapDeadline;
    private bool disposed;
    private string lastLifecycle = "none";
    private string lastAdoption = "none";
    private int adoptions;
    private NativeState lastNative;

    private enum RequestKind { Open, Quest, Map, GameCommand }
    private readonly record struct Request(RequestKind Kind, ushort Quest);
    private readonly record struct NativeState(bool Active, uint Addon, int Status, bool Visible);

    public NativeJournalBridge(IAddonLifecycle lifecycle, IFramework framework, IPluginLog log, IGameInteropProvider interop)
    {
        this.lifecycle = lifecycle;
        this.framework = framework;
        this.log = log;
        this.interop = interop;
        try
        {
            foreach (var type in Events) lifecycle.RegisterListener(type, OnAddon);
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
    public Func<uint, bool>? CanAdoptQuest { get; set; }
    public uint SelectedQuestId { get; private set; }
    public string? LastError { get; private set; }
    public string BridgeState => $"hook={commandHookReady}; native={lastNative}; pending={pendingAddon}; bypass={nativeBypass}; " +
        $"map={pendingMap}; adoptions={adoptions}; lifecycle={lastLifecycle}; lastAdoption={lastAdoption}";

    /// <summary>Runs the game's own Journal menu command, also used by its configured binding.
    /// This is an adoption diagnostic/action, unlike the explicit original-Journal fallback.</summary>
    public void InvokeGameJournal() => Enqueue(new Request(RequestKind.GameCommand, 0));

    /// <summary>Explicit fallback. Remains native until the user closes that Journal.</summary>
    public void OpenNative() => Enqueue(new Request(RequestKind.Open, 0));

    public void OpenNativeQuest(uint id)
    {
        if (!JournalText.TryClientId(id, out var clientId)) return;
        Enqueue(new Request(RequestKind.Quest, clientId));
    }

    /// <summary>Opens the selected quest using the typed native API, then its native map action.</summary>
    public void ShowOnMap(uint id)
    {
        if (!JournalText.TryClientId(id, out var clientId)) return;
        Enqueue(new Request(RequestKind.Map, clientId));
    }

    private void Enqueue(Request value)
    {
        lock (requestGate)
            if (!disposed) request = value;
    }

    private void OnAddon(AddonEvent type, AddonArgs args)
    {
        if (disposed || args.Addon.IsNull) return;
        var agent = AgentQuestJournal.Instance();
        if (agent == null) return;
        var addonId = agent->GetAddonId();
        // The live agent's addon identity is authoritative; no guessed addon name or node IDs.
        if (addonId is 0 or > ushort.MaxValue || args.Addon.Id != addonId) return;
        lastLifecycle = $"{type}/{args.AddonName}/{addonId}/visible={args.Addon.IsVisible}";
        if (type is AddonEvent.PostHide or AddonEvent.PostClose or AddonEvent.PreFinalize)
        {
            pendingAddon = 0;
            pendingAddress = 0;
            // OpenForQuest may replace a currently open journal addon. Closing that old
            // addon must not cancel the explicit fallback request being issued now.
            if (!issuingNativeRequest)
            {
                nativeBypass = false;
                bypassSeenActive = false;
                pendingMap = 0;
            }
            return;
        }
        if (!AdoptNativeOpens || nativeBypass || ToggleRequested == null) return;
        // A cached Journal may be populated by a requested/refresh update without a new
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
            var agent = AgentQuestJournal.Instance();
            if (agent == null)
            {
                pendingAddon = 0;
                pendingAddress = 0;
                pendingMap = 0;
                nativeBypass = false;
                bypassSeenActive = false;
                return;
            }
            lastNative = ReadState(agent);
            if (next is { Kind: RequestKind.GameCommand })
            {
                var module = UIModule.Instance();
                if (module != null && module->IsMainCommandUnlocked(4))
                {
                    var before = ReadState(agent);
                    module->ExecuteMainCommand(4); // MainCommand row 4, verified Journal in the installed sheet.
                    log.Information("Journal game command 4: before={Before}; after={After}", before, ReadState(agent));
                }
                next = null;
            }
            if (next is { } action)
            {
                // Set before Show/OpenForQuest: those calls may synchronously emit lifecycle events.
                nativeBypass = true;
                bypassSeenActive = false;
                pendingAddon = 0;
                pendingAddress = 0;
                pendingMap = 0;
                LastError = null;
                bypassDeadline = DateTime.UtcNow.AddSeconds(3);
                issuingNativeRequest = true;
                try
                {
                    if (action.Kind == RequestKind.Open)
                    {
                        if (agent->IsAgentActive() && agent->IsAddonShown()) agent->FocusAddon();
                        else
                        {
                            // Journal.Show is a toggle when AddonId != 0. Close an existing
                            // hidden instance first, then take the verified inactive Show path.
                            if (agent->IsAgentActive()) agent->Hide();
                            agent->Show();
                        }
                    }
                    else
                    {
                        // OpenForQuest also toggles an already selected active quest closed.
                        // Explicit details/map requests must open deterministically.
                        if (agent->IsAgentActive()) agent->Hide();
                        agent->OpenForQuest(action.Quest, 1);
                        if (action.Kind == RequestKind.Map)
                        {
                            pendingMap = action.Quest;
                            mapDeadline = DateTime.UtcNow.AddSeconds(3);
                        }
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
                if (!JournalCommandPolicy.KeepNativeBypass(visible, bypassSeenActive, DateTime.UtcNow >= bypassDeadline))
                {
                    nativeBypass = false;
                    bypassSeenActive = false;
                    pendingMap = 0;
                }
                if (pendingMap != 0)
                {
                    if (DateTime.UtcNow >= mapDeadline)
                    {
                        pendingMap = 0;
                        LastError = "The native quest details did not become ready. You can use their Map button.";
                    }
                    else if (active && agent->IsAddonReady() &&
                             (agent->SelectedQuestId & 0xFFFF) == pendingMap && agent->SelectedQuestType == 1)
                    {
                        pendingMap = 0;
                        agent->ShowOnMap();
                        // A successful map handoff can hide the Journal before this poll ever
                        // saw it visible. Its completed request is no longer an opening lease.
                        if (!ReadState(agent).Visible)
                        {
                            nativeBypass = false;
                            bypassSeenActive = false;
                        }
                    }
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
            SelectedQuestId = agent->SelectedQuestType == 1 && (agent->SelectedQuestId & 0xFFFF) != 0
                ? JournalText.QuestRowBase | (agent->SelectedQuestId & 0xFFFF) : 0;
            // Completed quests and leves remain in the native journal until this module
            // supplies their full data. A quest link must never turn into a different quest.
            if (agent->IsDisplayingCompletedQuests) return;
            if (agent->SelectedQuestType != 1 && agent->SelectedQuestId != 0) return;
            if (CanAdoptQuest?.Invoke(SelectedQuestId) == false) return;
            // If the replacement handler fails, leave the real Journal visible as the fallback.
            ToggleRequested.Invoke();
            var beforeHide = ReadState(agent);
            agent->Hide();
            lastNative = ReadState(agent);
            adoptions++;
            lastAdoption = $"{beforeHide} -> {lastNative}";
            log.Information("Journal adopted quest {Quest}: {State}", SelectedQuestId, lastAdoption);
        }
        catch (Exception ex)
        {
            pendingAddon = 0;
            pendingAddress = 0;
            pendingMap = 0;
            LastError = "The original Journal is available while the replacement recovers.";
            log.Error(ex, "Journal native bridge action failed; native fallback retained.");
        }
    }

    private static NativeState ReadState(AgentQuestJournal* agent)
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
                // vtable slot 206. Use the typed field/delegate, never a guessed signature/offset.
                commandHook = interop.HookFromAddress<UIModule.Delegates.ExecuteMainCommand>(
                    (nint)module->VirtualTable->ExecuteMainCommand, OnMainCommand);
                commandHook.Enable();
                commandHookReady = true;
                log.Information("Journal native main-command interception ready (Journal command 4).");
            }
            catch (Exception ex)
            {
                commandHook?.Disable();
                while (commandCallbacks != 0) Monitor.Wait(hookGate);
                commandHook?.Dispose();
                commandHookReady = false;
                hookFailed = true;
                log.Warning(ex, "Journal command interception unavailable; native Journal and quest-link adoption remain available.");
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
            if (disposed || !commandHookReady || command != 4 || !framework.IsInFrameworkUpdateThread || module != UIModule.Instance())
            {
                original(module, command);
                return;
            }
            try
            {
                var agent = AgentQuestJournal.Instance();
                if (agent != null)
                {
                    var state = ReadState(agent);
                    var bypass = nativeBypass && JournalCommandPolicy.KeepNativeBypass(state.Visible,
                        bypassSeenActive, DateTime.UtcNow >= bypassDeadline);
                    var supportedMode = !agent->IsDisplayingCompletedQuests &&
                        (agent->SelectedQuestId == 0 || agent->SelectedQuestType == 1);
                    var ready = MainCommandToggleRequested != null && CanAdoptQuest?.Invoke(0) == true;
                    if (JournalCommandPolicy.CanReplace(command, true, AdoptNativeOpens, ready, bypass,
                            state.Visible, supportedMode, module->IsMainCommandUnlocked(4) && agent->IsActivatable()))
                    {
                        MainCommandToggleRequested!.Invoke();
                        nativeBypass = false;
                        bypassSeenActive = false;
                        pendingAddon = 0;
                        pendingAddress = 0;
                        pendingMap = 0;
                        // Retire a hidden, cached native instance so later explicit native
                        // fallback starts from the game's real inactive state.
                        if (state.Active) agent->Hide();
                        lastNative = ReadState(agent);
                        log.Information("Journal native command 4 toggled the custom book; before={Before}; after={After}", state, lastNative);
                        return;
                    }
                }
            }
            catch (Exception ex)
            {
                log.Warning(ex, "Journal command replacement failed; forwarding the native Journal command.");
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
        CanAdoptQuest = null;
    }
}
