namespace XivSpell;

// Action requests and cast bars are provisional. Only the matching server
// action effect spends a step, including casts completed while relocating.
internal sealed class CastPlayback
{
    internal enum Outcome { Waiting, Completed, MovementInterrupted, Unknown }
    internal string? Request { get; private set; }
    private uint action;
    private ushort before, sequence;
    private bool bound, confirmed, sawCast, movedDuringCast;
    private long started, ended = -1;
    private int castMilliseconds;
    internal void Begin(string request, uint actionId, ushort previousSequence, ushort usedSequence, long now, int castTime)
    {
        Request = request; action = actionId; before = previousSequence; sequence = usedSequence;
        bound = usedSequence != previousSequence;
        confirmed = sawCast = movedDuringCast = false;
        started = now; ended = -1; castMilliseconds = castTime;
    }
    internal void Confirm(uint actionId, ushort sourceSequence)
    {
        if (Request == null || actionId != action || sourceSequence == 0) return;
        // Queued actions receive their sequence when they actually start.
        var distance = (ushort)(sourceSequence - before);
        if (bound ? sourceSequence == sequence : distance > 0 && distance < 32768) confirmed = true;
    }
    internal Outcome Poll(long now, bool casting, uint castAction, ushort usedSequence, bool moving)
    {
        if (Request == null) return Outcome.Waiting;
        if (confirmed) return Outcome.Completed;
        if (casting && castAction == action) {
            sawCast = true; ended = -1;
            movedDuringCast |= moving;
            if (!bound && usedSequence != before) { sequence = usedSequence; bound = true; }
        } else if (sawCast) {
            movedDuringCast |= moving;
            if (ended < 0) ended = now;
            // Leave time for a successful slidecast's server effect to arrive.
            if (movedDuringCast && now - ended >= 1500) return Outcome.MovementInterrupted;
        }
        return now - started >= Math.Max(5000, castMilliseconds + 3000) ? Outcome.Unknown : Outcome.Waiting;
    }
    internal void Reset() { Request = null; }
}
