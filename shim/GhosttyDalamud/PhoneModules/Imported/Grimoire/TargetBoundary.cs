namespace XivSpell;

// A playback belongs to one selected encounter target. Target changes never
// silently authorize another encounter, including a transition through no target.
internal sealed class TargetBoundary
{
    internal bool Bound { get; private set; }
    internal bool Stopped { get; private set; }
    internal ulong Target { get; private set; }
    internal void Start(ulong selected) { Target = selected; Bound = true; Stopped = false; }
    internal bool Observe(ulong selected, bool alive)
    {
        if (Stopped) return true;
        if (!Bound) { Start(selected); }
        if (selected != Target || Target != 0 && !alive) Stopped = true;
        return Stopped;
    }
    internal void Reset() { Bound = Stopped = false; Target = 0; }
}
