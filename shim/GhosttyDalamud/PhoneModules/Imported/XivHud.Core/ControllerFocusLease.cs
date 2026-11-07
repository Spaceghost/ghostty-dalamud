namespace XivHud.Core;

public readonly record struct ControllerSample(ulong Source, uint Held,
    float LeftX, float LeftY, float RightX, float RightY, bool ExtraButtonsNeutral = true)
{
    public bool Valid => Source != 0 && (Held & ~0xFFFFu) == 0
        && float.IsFinite(LeftX) && float.IsFinite(LeftY) && float.IsFinite(RightX) && float.IsFinite(RightY)
        && Math.Abs(LeftX) <= 1 && Math.Abs(LeftY) <= 1 && Math.Abs(RightX) <= 1 && Math.Abs(RightY) <= 1;
    public bool Neutral => Held == 0 && ExtraButtonsNeutral && Math.Abs(LeftX) <= .2f
        && Math.Abs(LeftY) <= .2f && Math.Abs(RightX) <= .2f && Math.Abs(RightY) <= .2f;
}

public readonly record struct ControllerFilter(bool All, uint Buttons);

/// <summary>Versioned IPC value. Buttons use the native directional/face/shoulder
/// mask; sticks are normalized to [-1,1], with negative Y pointing up.</summary>
public readonly record struct ControllerFrame(int Version, string Phase, ulong Sequence,
    uint Held, uint Pressed, uint Released, float LeftX, float LeftY, float RightX, float RightY, ulong Session = 1);

/// <summary>One focused XivHud feature owns the pad only through a fresh UI lease.
/// Call under the broker's lock. No game globals, input injection or native pointers.</summary>
public sealed class ControllerFocusLease : IDisposable
{
    public const double MaximumLeaseSeconds = .100;
    private enum Phase { None, WaitingForNeutral, Active, Draining }
    private Phase phase;
    private string? owner;
    private ulong generation, source, sequence;
    private double deadline, lastTime = double.NaN, lastPoll = double.NaN;
    private ControllerSample sample;
    private uint pressed, released, drain;
    private int neutralPolls;
    private bool disposed;
    private readonly ulong session;

    public ControllerFocusLease(ulong session = 1)
    {
        if (session == 0) throw new ArgumentOutOfRangeException(nameof(session));
        this.session = session;
    }

    public bool Renew(string name, ulong focusGeneration, double now)
    {
        if (!Observe(now) || !ValidOwner(name) || focusGeneration == 0) return false;
        Expire(now);
        if (owner is not null && (owner != name || generation != focusGeneration)) return false;
        if (owner is null || phase == Phase.Draining)
        {
            owner = name; generation = focusGeneration; phase = Phase.WaitingForNeutral;
            source = 0; sample = default; neutralPolls = 0; pressed = released = drain = 0;
        }
        deadline = now + MaximumLeaseSeconds;
        return true;
    }

    public bool Release(string name, ulong focusGeneration, double now)
    {
        if (!Observe(now)) return false;
        Expire(now);
        if (owner != name || generation != focusGeneration) return false;
        // Release analog movement and unrelated/new buttons immediately. Only
        // buttons held by this owner are quarantined until up, at most100ms.
        drain = sample.Held; pressed = released = 0;
        phase = Phase.Draining; deadline = now + MaximumLeaseSeconds;
        if (drain == 0) Clear();
        return true;
    }

    public ControllerFilter Poll(ControllerSample next, bool eligible, double now)
    {
        if (!Observe(now)) return default;
        Expire(now);
        if (!eligible || !next.Valid) { Clear(); return default; }
        if (owner is null) return default;
        if (phase == Phase.Draining)
        {
            if (next.Source != source) { Clear(); return default; }
            var mask = drain;
            drain &= next.Held;
            if (drain == 0) Clear();
            return new(false, mask);
        }
        if (next.Source != source)
        {
            source = next.Source; phase = Phase.WaitingForNeutral;
            neutralPolls = 0; sample = default; pressed = released = 0;
        }
        lastPoll = now;
        sequence++;
        if (phase == Phase.WaitingForNeutral)
        {
            sample = next;
            neutralPolls = next.Neutral ? neutralPolls + 1 : 0;
            if (neutralPolls >= 2) phase = Phase.Active;
            return new(true, 0xFFFF);
        }
        pressed |= next.Held & ~sample.Held;
        released |= sample.Held & ~next.Held;
        sample = next;
        return new(true, 0xFFFF);
    }

    public ControllerFrame? Read(string name, ulong focusGeneration, double now)
    {
        if (!Observe(now)) return null;
        Expire(now);
        if (owner != name || generation != focusGeneration) return null;
        if (phase != Phase.Active)
            return new(1, phase.ToString(), sequence, 0, 0, 0, 0, 0, 0, 0, session);
        if (!double.IsFinite(lastPoll) || now - lastPoll > MaximumLeaseSeconds) { Clear(); return null; }
        var frame = new ControllerFrame(1, "Active", sequence, sample.Held, pressed, released,
            sample.LeftX, sample.LeftY, sample.RightX, sample.RightY, session);
        pressed = released = 0;
        return frame;
    }

    public void Invalidate() => Clear();
    public void Dispose() { disposed = true; Clear(); }

    private bool Observe(double now)
    {
        if (disposed) return false;
        if (!double.IsFinite(now) || double.IsFinite(lastTime) && now < lastTime)
        { Clear(); lastTime = double.NaN; return false; }
        lastTime = now;
        return true;
    }
    private void Expire(double now) { if (owner is not null && now > deadline) Clear(); }
    private static bool ValidOwner(string value) => value is { Length: >0 and <=64 }
        && value.StartsWith("XivHud.", StringComparison.Ordinal)
        && value.All(c => char.IsAsciiLetterOrDigit(c) || c is '.' or '-' or '_');
    private void Clear()
    {
        phase = Phase.None; owner = null; generation = source = 0;
        sample = default; pressed = released = drain = 0; neutralPolls = 0; lastPoll = double.NaN;
    }
}
