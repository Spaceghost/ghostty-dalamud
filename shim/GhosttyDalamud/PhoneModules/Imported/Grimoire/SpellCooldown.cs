using FFXIVClientStructs.FFXIV.Client.Game;

namespace XivSpell;

internal readonly record struct SpellTiming(float Remaining, float Total, bool Casting)
{
    internal float Progress => Total <= 0 ? 1 : Math.Clamp(1 - Remaining / Total, 0, 1);
    internal string Label => Remaining > .05f ? (Casting ? "CAST " : "") + Remaining.ToString("0.0") + "s" : "";
}

internal sealed partial class Plugin
{
    private unsafe SpellTiming ReadCooldown(SpellWeave.Rune rune, int index)
    {
        var manager = ActionManager.Instance();
        var card = cards.FirstOrDefault(c => c.Id == rune.CardId);
        if (manager == null || card == null) return default;
        var action = rune.PlayedAction != 0 ? rune.PlayedAction : manager->GetAdjustedActionId(card.Action);
        if (action == 0) return default;
        float remaining = 0, total = 0;
        if (!manager->IsActionOffCooldown(ActionType.Action, action)) {
            var duration = manager->GetRecastTime(ActionType.Action, action);
            var elapsed = manager->GetRecastTimeElapsed(ActionType.Action, action);
            remaining = Math.Max(0, duration - elapsed); total = duration;
            var additional = manager->GetAdditionalRecastGroup(ActionType.Action, action);
            if (additional >= 0 && manager->GetRecastGroupDetail(additional) is var extra && extra != null && extra->IsActive) {
                var extraRemaining = Math.Max(0, extra->Total - extra->Elapsed);
                if (extraRemaining > remaining) { remaining = extraRemaining; total = extra->Total; }
            }
        }
        if (manager->AnimationLock > remaining) { remaining = manager->AnimationLock; total = Math.Max(.6f, remaining); }
        var casting = index == weave.Cursor && objects.LocalPlayer?.IsCasting == true;
        if (casting) {
            var castRemaining = Math.Max(0, manager->CastTimeTotal - manager->CastTimeElapsed);
            if (castRemaining > remaining) { remaining = castRemaining; total = manager->CastTimeTotal; }
        }
        return new(remaining, total, casting);
    }
}
