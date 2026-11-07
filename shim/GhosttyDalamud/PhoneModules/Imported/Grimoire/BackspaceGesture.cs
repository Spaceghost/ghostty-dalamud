namespace XivSpell;

// Repeat draft deletion first; only an empty draft can arm the line-clear hold.
// All timing is monotonic and independent of OS repeat and game frame rate.
internal sealed class BackspaceGesture
{
    internal const long HoldMilliseconds = 600;
    internal const long RepeatDelayMilliseconds = 300;
    internal const long RepeatMilliseconds = 45;
    private bool held, cleared;
    private long started, nextRepeat;
    internal bool EraseText { get; private set; }
    internal void Press(long now)
    {
        if (held) return;
        held = true; cleared = false; started = now;
        nextRepeat = now + RepeatDelayMilliseconds;
    }
    internal void Release() { held = cleared = EraseText = false; }
    internal bool Poll(long now, bool down, bool enabled, bool hasDraft = false)
    {
        EraseText = false;
        if (!down || !enabled) { Release(); return false; }
        if (!held || cleared) return false;
        if (hasDraft) {
            // Restart the destructive hold while there is still text. Repeats
            // are text-only so a queued repeat cannot accidentally remove a rune.
            started = now;
            if (now >= nextRepeat) {
                EraseText = true;
                nextRepeat = now + RepeatMilliseconds;
            }
            return false;
        }
        if (now - started < HoldMilliseconds) return false;
        cleared = true;
        return true;
    }
}
