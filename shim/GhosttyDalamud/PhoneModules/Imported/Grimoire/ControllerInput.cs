using Dalamud.Plugin.Services;

namespace XivSpell;

internal sealed partial class Plugin
{
    private GrimoirePad? pad;
    private readonly ControllerComposer composer = new();
    private ulong padSequence, padSession;
    private void ReadController(bool eligible)
    {
        if (pad == null) return;
        eligible &= !gamepad.EnableGamepadNav;
        var frame = pad.Read(eligible, composer.Active);
        if (!eligible) { composer.Active = false; return; }
        if (pad.TakeOpen()) {
            composer.Active = !composer.Active; padSequence = 0;
            if (composer.Active) { InterruptWeave("Controller composing", true); barVisible = true; }
        }
        if (!composer.Active || frame is not { Phase: "Active" } f || f.Sequence == 0) { padSequence = 0; return; }
        if (f.Session != padSession) { padSession = f.Session; padSequence = 0; }
        if (f.Sequence <= padSequence) return;
        padSequence = f.Sequence;
        var pressed = f.Pressed;
        if ((pressed & 128) != 0) { CardInput("cancel", "voice"); composer.Active = false; InterruptWeave("Stopped", true); return; }
        if ((pressed & 32768) != 0) { StartPlayback(); return; }
        if ((pressed & 16384) != 0) { StartPlayback(true); return; }
        if ((pressed & 4) != 0) composer.SelectCard(-1, cards.Length);
        if ((pressed & 8) != 0) composer.SelectCard(1, cards.Length);
        if ((pressed & 1) != 0) composer.SelectTarget(-1);
        if ((pressed & 2) != 0) composer.SelectTarget(1);
        if ((pressed & 256) != 0) composer.SelectCondition(-1);
        if ((pressed & 2048) != 0) composer.SelectCondition(1);
        if ((pressed & 64) != 0) CancelWeaveTicket(weave.Backspace());
        if ((pressed & 16) != 0) CardInput("toggle", "voice");
        if ((pressed & 32) != 0 && cards.Length > 0) {
            if (weave.Draft.Length > 0) SubmitDraft();
            else {
                var card = cards[Math.Clamp(composer.CardIndex, 0, cards.Length - 1)];
                weave.Add(composer.Line(card.Phrase), card.Id);
            }
        }
    }
    private void SubmitDraft()
    {
        if (System.Text.RegularExpressions.Regex.IsMatch(weave.Draft, @"^target\s+(?:(?:nearest|closest)\s+)?(?:enemy|enemies|mob|mobs|enemy/mob|self|focus|boss|tank[1-8]?|healer[1-8]?|party[1-8])$", System.Text.RegularExpressions.RegexOptions.IgnoreCase)) {
            CardInput(weave.Draft, "command"); weave.ClearDraft(); return;
        }
        draftRequest = Guid.NewGuid().ToString("N");
        draftRequestRevision = weave.DraftRevision;
        CardInput(weave.Draft, weave.Draft.StartsWith('?') ? "translate" : "compile", requestId: draftRequest);
        weave.Hint = weave.Draft.StartsWith('?') ? "Translating locally…" : "Checking line…";
    }
}
