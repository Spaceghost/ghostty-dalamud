namespace XivHud.Character;

internal sealed record CharacterPadFrame(int Version, string Phase, ulong Sequence,
    uint Held, uint Pressed, uint Released, float LeftX, float LeftY, float RightX, float RightY, ulong Session = 0);

/// <summary>Semantic input and held-direction repeat from fresh broker frames only.</summary>
internal sealed class CharacterControllerInput
{
    private ulong sequence, session;
    private int vertical, horizontal;
    private double nextVertical, nextHorizontal, previousTime;
    internal void Reset() { sequence = 0; vertical = horizontal = 0; nextVertical = nextHorizontal = previousTime = 0; }

    internal IReadOnlyList<CharacterControllerIntent> Read(CharacterPadFrame frame, double now, bool swap)
    {
        if (frame.Version != 1 || frame.Phase != "Active" || !double.IsFinite(now) ||
            !float.IsFinite(frame.LeftX) || !float.IsFinite(frame.LeftY) || !float.IsFinite(frame.RightX) || !float.IsFinite(frame.RightY))
        { Reset(); return []; }
        if (frame.Session != session) { Reset(); session = frame.Session; }
        if (frame.Sequence == 0 || frame.Sequence <= sequence) return [];
        sequence = frame.Sequence;
        var elapsed = previousTime == 0 ? 1 / 60d : Math.Clamp(now - previousTime, 0, .05);
        previousTime = now;
        var result = new List<CharacterControllerIntent>(6);
        // Closing or opening a subpage takes precedence over simultaneous action presses.
        if ((frame.Pressed & (swap ? 32u : 128u)) != 0) return [new(CharacterControllerCommand.Back)];
        if ((frame.Pressed & 32768) != 0) return [new(CharacterControllerCommand.Appearance)];
        if ((frame.Pressed & 16384) != 0) return [new(CharacterControllerCommand.Armoury)];
        // Native masks are named physical locations; label style does not change behavior.
        AddPress(swap ? 128u : 32u, CharacterControllerCommand.Confirm);
        AddPress(64, CharacterControllerCommand.Secondary);
        AddPress(16, CharacterControllerCommand.NativeDetails);
        AddPress(256, CharacterControllerCommand.PreviousTab);
        AddPress(2048, CharacterControllerCommand.NextTab);
        var v = (frame.Held & 1) != 0 ? -1 : (frame.Held & 2) != 0 ? 1 : 0;
        var h = (frame.Held & 4) != 0 ? -1 : (frame.Held & 8) != 0 ? 1 : 0;
        if (v == 0 && h == 0)
        {
            if (Math.Abs(frame.LeftY) >= Math.Abs(frame.LeftX) && Math.Abs(frame.LeftY) >= .55f) v = Math.Sign(frame.LeftY);
            else if (Math.Abs(frame.LeftX) >= .55f) h = Math.Sign(frame.LeftX);
        }
        Repeat(v, (frame.Pressed & (v < 0 ? 1u : 2u)) != 0, ref vertical, ref nextVertical, CharacterControllerCommand.Up, CharacterControllerCommand.Down);
        Repeat(h, (frame.Pressed & (h < 0 ? 4u : 8u)) != 0, ref horizontal, ref nextHorizontal, CharacterControllerCommand.Left, CharacterControllerCommand.Right);
        // A press and release entirely between UI frames still has one accumulated press edge.
        if (v == 0) { AddPress(1, CharacterControllerCommand.Up); AddPress(2, CharacterControllerCommand.Down); }
        if (h == 0) { AddPress(4, CharacterControllerCommand.Left); AddPress(8, CharacterControllerCommand.Right); }
        if (Math.Abs(frame.RightY) > .18f)
            result.Add(new(CharacterControllerCommand.Scroll, Math.Clamp(frame.RightY, -1, 1) * 340 * (float)elapsed));
        return result;

        void AddPress(uint bit, CharacterControllerCommand command)
        { if ((frame.Pressed & bit) != 0) result.Add(new(command)); }
        void Repeat(int value, bool pressed, ref int previous, ref double next, CharacterControllerCommand negative, CharacterControllerCommand positive)
        {
            if (value == 0) { previous = 0; return; }
            if (pressed || value != previous) { result.Add(new(value < 0 ? negative : positive)); next = now + .35; }
            else if (now >= next) { result.Add(new(value < 0 ? negative : positive)); next = now + .09; }
            previous = value;
        }
    }
}

internal readonly record struct CharacterControllerLabels(string Confirm, string Back, string Secondary,
    string Details, string Tabs, string Appearance, string Armoury)
{
    internal static CharacterControllerLabels For(string? style, bool swap)
    {
        var labels = style switch
        {
            "Xbox" => new CharacterControllerLabels("A", "B", "X", "Y", "LB / RB", "Menu", "View"),
            "Generic" => new CharacterControllerLabels("South", "East", "West", "North", "L1 / R1", "Start", "Select"),
            _ => new CharacterControllerLabels("×", "○", "□", "△", "L1 / R1", "Options", "Create"),
        };
        return swap ? labels with { Confirm = labels.Back, Back = labels.Confirm } : labels;
    }
}
