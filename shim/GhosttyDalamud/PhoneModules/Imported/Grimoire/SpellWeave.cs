namespace XivSpell;

// Pure input/queue state; the game adapter owns timing, icons and execution.
public sealed class SpellWeave
{
    public sealed record Rune(string Command, string CardId, long Created)
    {
        public string? TargetName { get; init; }
        public string? TargetSelector { get; init; }
        public ulong TargetId { get; init; }
        public uint PlayedAction { get; init; }
        public bool? ConditionResult { get; init; }
    }
    public sealed record SavedState(Rune[] Runes, string Draft, int Cursor, bool InputMode);
    public SavedState SaveState() => new(Runes.ToArray(), Draft, Cursor, InputMode);
    public void Restore(SavedState? state)
    {
        if (state == null) return;
        Runes.Clear(); Runes.AddRange((state.Runes ?? []).Take(Capacity));
        Draft = (state.Draft ?? "")[..Math.Min(state.Draft?.Length ?? 0, 255)];
        Cursor = Math.Clamp(state.Cursor, 0, Runes.Count); InputMode = state.InputMode;
        InFlight = LastRequest = null; Paused = !Finished; DraftRevision++;
        Hint = Paused ? "Weave restored · > continue  /  . restart" : "Type a spell to weave it";
    }
    public List<Rune> Runes { get; } = [];
    public string Draft { get; private set; } = "";
    public bool InputMode { get; private set; } = true;
    public bool Paused { get; private set; }
    public int Cursor { get; private set; }
    public string? InFlight { get; private set; }
    public string? LastRequest { get; private set; }
    public long DraftRevision { get; private set; }
    public bool Finished => Cursor >= Runes.Count;
    public string Hint { get; set; } = "Type a spell to weave it";
    private readonly List<Rune> previous = [];
    public const int Capacity = 32;

    public void EnterInput() { InputMode = true; Hint = Paused ? "> to continue  /  . to start again" : "Type a spell to weave it"; }
    public void Append(char value, Func<string, (string Command, string CardId)?> resolve)
    {
        if (!InputMode || Draft.Length >= 255 || char.IsControl(value)) return;
        Draft += char.ToLowerInvariant(value);
        DraftRevision++;
        if (Draft.StartsWith("if ", StringComparison.OrdinalIgnoreCase) || Draft.StartsWith("on ", StringComparison.OrdinalIgnoreCase) || Draft.StartsWith('?')) return;
        var match = resolve(Draft.Trim());
        if (match is { } rune) Add(rune.Command, rune.CardId);
    }
    public bool Add(string command, string cardId)
    {
        if (Finished && InFlight == null && !Paused && Runes.Count > 0 && Environment.TickCount64 - Runes[^1].Created > 4000) { previous.Clear(); previous.AddRange(Runes); Runes.Clear(); Cursor = 0; }
        if (Runes.Count >= Capacity) { Hint = "Weave full · finish or interrupt first"; return false; }
        Runes.Add(new(command, cardId, Environment.TickCount64)); Draft = "";
        DraftRevision++;
        Hint = Paused ? "Spell woven · > continues" : "Spell woven";
        return true;
    }
    public string? Backspace()
    {
        DraftRevision++;
        if (Draft.Length > 0) { Draft = Draft[..^1]; return null; }
        if (Runes.Count == 0) return null;
        string? cancelled = null;
        if (Runes.Count - 1 == Cursor && InFlight != null) { cancelled = InFlight; InFlight = null; }
        Runes.RemoveAt(Runes.Count - 1);
        Cursor = Math.Min(Cursor, Runes.Count);
        if (Runes.Count == 0) { previous.Clear(); Paused = false; }
        Hint = Runes.Count == 0 ? "Line empty · type a spell" : "Spell removed · hold Backspace to clear";
        return cancelled;
    }
    public string? ClearLine()
    {
        DraftRevision++;
        var cancelled = InFlight;
        InFlight = LastRequest = null;
        Runes.Clear(); previous.Clear(); Draft = ""; Cursor = 0; Paused = false;
        Hint = "Line cleared · type a spell";
        return cancelled;
    }
    public string? Interrupt(string reason, bool control = false)
    {
        DraftRevision++;
        var cancelled = InFlight; InFlight = null;
        Paused = !Finished;
        if (control) InputMode = false;
        Hint = reason + " · . repeat  /  > continue  /  i weave";
        return cancelled;
    }
    public void StopAfterCurrent(string reason)
    {
        DraftRevision++; Paused = !Finished; InputMode = false; Hint = reason;
        // Retain an actual cast until its server result resolves. It can still
        // spend this step, but no following step is authorized by that result.
    }
    public void EnterControl() { InputMode = false; }
    public void Retry(string request, string message)
    {
        if (request != InFlight) return;
        InFlight = null; Hint = message;
        // Explicit Escape/disarm still owns Paused; movement never changes it.
    }
    public void Resume() { Paused = false; Hint = Finished ? "Nothing left to continue" : "Continuing weave"; }
    public string? Repeat()
    {
        DraftRevision++;
        var cancelled = InFlight; InFlight = null;
        if (Runes.Count == 0) Runes.AddRange(previous);
        for (int i = 0; i < Runes.Count; i++) Runes[i] = Runes[i] with { TargetName=null, TargetSelector=null, TargetId=0, PlayedAction=0, ConditionResult=null };
        Cursor = 0; Draft = ""; Paused = false;
        Hint = Runes.Count == 0 ? "No weave to repeat" : "Repeating weave";
        return cancelled;
    }
    public Rune? Next => !Paused && InFlight == null && !Finished ? Runes[Cursor] : null;
    public void Begin(string request) { if (Next == null) throw new InvalidOperationException("No ready rune"); InFlight = request; LastRequest = request; }
    public void RecordTarget(string request, string selector, string name, ulong id, uint action)
    {
        if (request != InFlight || Cursor >= Runes.Count) return;
        Runes[Cursor] = Runes[Cursor] with { TargetSelector=selector, TargetName=name, TargetId=id, PlayedAction=action };
    }
    public void RecordCondition(string request, bool? passed)
    {
        if (request != InFlight || Cursor >= Runes.Count) return;
        Runes[Cursor] = Runes[Cursor] with { ConditionResult=passed };
    }
    public void Complete(string request, bool accepted, string message)
    {
        if (request != InFlight) return; // late results cannot advance an interrupted weave
        InFlight = null;
        if (accepted) { Cursor++; Hint = Paused ? "Stopped · Enter / > continue · . restart" : Finished ? "Weave complete · . repeat" : "Weaving"; }
        else { Paused = true; Hint = message + " · > retry this spell"; }
    }
    public void ClearDraft() { Draft = ""; DraftRevision++; }
    public void SetDraft(string text) { if (text.Length > 255) throw new ArgumentException("Line is too long"); Draft = text; DraftRevision++; }
}
