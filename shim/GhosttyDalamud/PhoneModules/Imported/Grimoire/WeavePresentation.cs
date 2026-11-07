using System.Text.RegularExpressions;

namespace XivSpell;

internal readonly record struct RuneTarget(ulong ActorId, string Selector, string Name)
{
    internal string Key => Selector + ":" + ActorId + ":" + Name;
}
internal readonly record struct RuneStack(int Start, int Count, SpellWeave.Rune Rune, RuneTarget Target)
{
    internal bool Contains(int cursor) => cursor >= Start && cursor < Start + Count;
    internal bool Completed(int cursor) => cursor >= Start + Count;
    internal int Remaining(int cursor) => Math.Clamp(Start + Count - cursor, 0, Count);
    internal int DisplayCount(int cursor) => Completed(cursor) ? Count : Remaining(cursor);
}

internal static class WeavePresentation
{
    internal static void Fill(List<RuneStack> output, SpellWeave weave, Func<SpellWeave.Rune, int, RuneTarget> target)
    {
        output.Clear();
        for (int i = 0; i < weave.Runes.Count; i++) {
            var rune = weave.Runes[i]; var badge = target(rune, i);
            if (output.Count > 0) {
                var previous = output[^1];
                if (previous.Rune.CardId == rune.CardId && previous.Rune.Command == rune.Command && previous.Target.Key == badge.Key) {
                    output[^1] = previous with { Count=previous.Count + 1 };
                    continue;
                }
            }
            output.Add(new(i, 1, rune, badge));
        }
    }

    private static readonly Regex Keywords = new(@"\b(if|then|else|and|or|not|on)\b", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
    internal static string Logic(string text) => Keywords.Replace(text, match => match.Value.ToLowerInvariant() switch {
        "if" => "◇ IF", "then" => "→ THEN", "else" => "↳ ELSE", "and" => "∧ AND", "or" => "∨ OR", "not" => "¬ NOT", _ => "ON",
    });
    internal static bool HasLogic(string text) => Regex.IsMatch(text, @"\b(if|then|else|and|or|not)\b", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
    internal static string Clip(string value, int length) => value.Length <= length ? value : value[..(length - 1)] + "…";
    internal static string TargetLabel(string target) => target switch {
        "self" => "SELF", "current" => "TARGET", "focus" => "FOCUS", "targetOfTarget" => "TOT",
        "nearest" => "NEAREST", "nearestmob" => "NEAR MOB", "healer" => "HEALER", "lowest" => "LOW HP", "role" => "AUTO ROLE",
        _ when target.StartsWith("name:") => "NAMED", _ => target.ToUpperInvariant(),
    };
}
