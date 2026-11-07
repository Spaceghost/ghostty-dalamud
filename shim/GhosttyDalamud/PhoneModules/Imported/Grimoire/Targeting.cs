using System.Numerics;
using System.Text.RegularExpressions;
using Dalamud.Game.ClientState.Objects.Enums;
using Dalamud.Game.ClientState.Objects.Types;

namespace XivSpell;

internal sealed partial class Plugin
{
    private ulong bossTarget;
    private uint bossTerritory;
    private static bool IsEnemy(IGameObject? actor) => actor is IBattleNpc npc &&
        npc.BattleNpcKind == BattleNpcSubKind.Combatant && (npc.StatusFlags & StatusFlags.Hostile) != 0 && npc.IsTargetable && !npc.IsDead;

    private IGameObject? ResolveEnemy(bool mobsOnly, bool nearest = false)
    {
        if (!nearest && !mobsOnly && IsEnemy(targets.Target)) return targets.Target;
        var origin = objects.LocalPlayer?.Position ?? Vector3.Zero;
        return objects.Where(o => IsEnemy(o) && (!mobsOnly || o.GameObjectId != bossTarget))
            .OrderBy(o => Vector3.DistanceSquared(origin, o.Position)).FirstOrDefault();
    }

    private IGameObject? ResolvePartyRole(string selector)
    {
        int number = char.IsDigit(selector[^1]) ? selector[^1] - '0' : 1;
        string role = char.IsDigit(selector[^1]) ? selector[..^1] : selector;
        return party.Where(p => role switch {
            "tank" => p.ClassJob.Value.Role == 1, "healer" => p.ClassJob.Value.Role == 4,
            "melee" => p.ClassJob.Value.Role == 2, "ranged" => p.ClassJob.Value.Role == 3,
            "dps" => p.ClassJob.Value.Role is 2 or 3, _ => false,
        }).Skip(number - 1).FirstOrDefault()?.GameObject;
    }

    private void MarkBoss()
    {
        if (!IsEnemy(targets.Target)) { weave.Hint = "Select a living hostile boss, then :boss"; return; }
        bossTarget = targets.Target!.GameObjectId;
        bossTerritory = client.TerritoryType;
        weave.Hint = "Boss: " + targets.Target.Name.TextValue;
    }

    private static readonly Regex ExplicitTarget = new("^on\\s+(?:\"(?<name>[^\"]+)\"|(?<selector>\\S+))\\s+", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
    private RuneTarget RuneTarget(SpellWeave.Rune rune, int index)
    {
        if (rune.TargetName != null && (index < weave.Cursor || index == weave.Cursor && (weave.InFlight != null || weave.Paused)))
            return new(rune.TargetId, rune.TargetSelector ?? "current", rune.TargetName);
        if (rune.Command.StartsWith("if ", StringComparison.OrdinalIgnoreCase)) return new(0, "IF", "conditional");
        var match = ExplicitTarget.Match(rune.Command);
        string selector = match.Success ? match.Groups["name"].Success ? "name:" + match.Groups["name"].Value : match.Groups["selector"].Value
            : cards.FirstOrDefault(c => c.Id == rune.CardId)?.Target ?? "current";
        try {
            var actor = Resolve(selector);
            return new(actor?.GameObjectId ?? 0, selector, actor?.Name.TextValue ?? (selector == "boss" ? "mark :boss" : "unavailable"));
        } catch { return new(0, selector, "ambiguous"); }
    }
}
