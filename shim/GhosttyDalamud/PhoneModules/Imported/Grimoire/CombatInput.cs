using System.Runtime.InteropServices;
using Dalamud.Game.ClientState.Conditions;
using Dalamud.Game.ClientState.Keys;
using Dalamud.Plugin.Services;

namespace XivSpell;

internal sealed partial class Plugin
{
    [DllImport("user32.dll")]
    private static extern short GetAsyncKeyState(int key);
    [DllImport("user32.dll", EntryPoint = "GetForegroundWindow")]
    private static extern nint CombatForegroundWindow();
    [DllImport("user32.dll", EntryPoint = "GetWindowThreadProcessId")]
    private static extern uint CombatWindowProcess(nint window, out uint process);
    private readonly CombatEnterCapture combatEnter = new();
    private bool spellInputActive, otherTextInputActive;
    private int combatFocusRequested;

    private void InputUpdate(IFramework _)
    {
        if (!client.IsLoggedIn || client.TerritoryType != bossTerritory) bossTarget = 0;
        nativeChat.Update(objects.LocalPlayer != null);
        var down = (GetAsyncKeyState((int)VirtualKey.RETURN) & 0x8000) != 0;
        CombatWindowProcess(CombatForegroundWindow(), out var foreground);
        // Modified Enter retains its existing meaning; do not steal another
        // plugin's active text editor. An active Grimoire receives Enter normally.
        var modified = (GetAsyncKeyState((int)VirtualKey.CONTROL) & 0x8000) != 0 ||
            (GetAsyncKeyState((int)VirtualKey.MENU) & 0x8000) != 0 ||
            (GetAsyncKeyState((int)VirtualKey.SHIFT) & 0x8000) != 0;
        var eligible = foreground == (uint)Environment.ProcessId && objects.LocalPlayer != null && conditions[ConditionFlag.InCombat] &&
            !conditions[ConditionFlag.BetweenAreas] && !conditions[ConditionFlag.OccupiedInCutSceneEvent] &&
            !modified && !editorOpen && (!otherTextInputActive || visible);
        var request = combatEnter.Poll(down, eligible, spellInputActive, barVisible);
        keyboard.CaptureCombatEnter = eligible;
        var eventFocus = keyboard.TakeCombatEnter() && eligible;
        if (request.Consume) keys[VirtualKey.RETURN] = false;
        if (!request.Focus && !eventFocus) return;
        barVisible = true;
        visible = false;
        Interlocked.Exchange(ref combatFocusRequested, 1);
    }
}
