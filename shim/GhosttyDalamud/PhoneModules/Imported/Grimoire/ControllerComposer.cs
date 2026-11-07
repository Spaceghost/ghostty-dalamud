namespace XivSpell;

internal sealed class ControllerComposer
{
    internal bool Active { get; set; }
    internal int CardIndex, TargetIndex, ConditionIndex;
    internal static readonly string[] Targets = ["current", "self", "focus", "tank1", "tank2", "healer1", "healer2", "lowest", "boss", "mob", "enemy", "nearest", "nearestmob", "party2", "dps1"];
    internal static readonly string[] Conditions = ["", "self.hp < 50%", "target.exists", "target.hp > 0", "self.mp > 20%", "not self.casting", "self.hp < 50% and target.exists"];
    internal string Target => Targets[TargetIndex];
    internal string Condition => Conditions[ConditionIndex];
    internal string Line(string phrase) => (Condition.Length == 0 ? "" : "if " + Condition + " then ") + "on " + Target + " " + phrase;
    internal void SelectCard(int direction, int count) => CardIndex = Wrap(CardIndex + direction, count);
    internal void SelectTarget(int direction) => TargetIndex = Wrap(TargetIndex + direction, Targets.Length);
    internal void SelectCondition(int direction) => ConditionIndex = Wrap(ConditionIndex + direction, Conditions.Length);
    private static int Wrap(int value, int count) => count <= 0 ? 0 : (value % count + count) % count;
}
