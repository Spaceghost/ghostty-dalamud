namespace XivSpell;

// Physical edges are tracked even while capture is unavailable. Enter held
// across a zone/combat/focus change must not become a new input request.
internal sealed class CombatEnterCapture
{
    private bool wasDown;
    internal (bool Consume, bool Focus) Poll(bool down, bool eligible, bool inputActive, bool barVisible)
    {
        bool fresh = down && !wasDown;
        wasDown = down;
        return (down && eligible, down && eligible && fresh && (!inputActive || !barVisible));
    }
}
