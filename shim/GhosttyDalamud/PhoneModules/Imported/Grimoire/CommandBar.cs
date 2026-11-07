using System.Numerics;
using System.Runtime.InteropServices;
using Dalamud.Plugin.Services;
using FFXIVClientStructs.FFXIV.Client.UI;
using FFXIVClientStructs.FFXIV.Client.Game;
using FFXIVClientStructs.FFXIV.Component.GUI;
using KamiToolKit;
using KamiToolKit.Nodes;
using KamiToolKit.UiOverlay;
using KamiToolKit.Enums;

namespace XivSpell;

internal sealed partial class Plugin
{
    private bool barVisible = true;
    private bool focusSpellInput;
    private string commandText = ""; // spellbook's Type button hands a phrase to the weave
    private Dictionary<string, string> expansions = new();
    private long lastRuntimePoll;
    private readonly SpellWeave weave = new();
    private readonly HashSet<string> cancelledWeaves = [];
    private readonly SpellKeyboard keyboard = new();
    private Task? hudStartup;
    private OverlayController? hudController;
    private WeaveHud? hud;
    private bool disposed;
    private readonly CastPlayback castPlayback = new();
    private readonly TargetBoundary targetBoundary = new();
    private ulong encounterActor;
    private long speechGeneration = -1, speechRevision;
    private sealed record CastResult(bool Accepted, bool Retry, string Message);
    private readonly Dictionary<string, CastResult> castResults = new();
    private ActionEffects? actionEffects;
    private bool moving;
    private long lastMotionAt, retryAt;
    private string? draftRequest;
    private long draftRequestRevision;
    private long weaveSentAt;
    private Vector3? lastPlayerPosition;
    private readonly IGameGui gameGui;

    [DllImport("user32.dll")] private static extern nint GetForegroundWindow();
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(nint window, out uint process);

    private static string Normalize(string value) => string.Join(' ', value.Trim().ToLowerInvariant().Split(' ', StringSplitOptions.RemoveEmptyEntries));
    private (string Command, string CardId)? ResolveRune(string value)
    {
        var name = Normalize(value);
        var seen = new HashSet<string>();
        while (expansions.TryGetValue(name, out var full)) {
            if (!seen.Add(name)) return null;
            name = Normalize(full);
        }
        var card = cards.FirstOrDefault(c => Normalize(c.Phrase) == name || Normalize(c.Id) == name ||
            (c.Aliases?.Any(alias => Normalize(alias) == name) ?? false));
        return card == null ? null : (name, card.Id);
    }

    private void CancelWeaveTicket(string? ticket)
    {
        if (ticket == null) return;
        if (cancelledWeaves.Count >= 256) cancelledWeaves.Clear();
        cancelledWeaves.Add(ticket);
        if (castPlayback.Request == ticket) castPlayback.Reset();
        if (castResults.Count >= 256) castResults.Clear();
        castResults[ticket] = new(false, false, "Weave interrupted");
    }
    private void InterruptWeave(string reason, bool control = false)
    {
        CancelWeaveTicket(weave.Interrupt(reason, control));
        StopFollowing(reason);
    }

    private bool CheckEncounterTarget()
    {
        var selected = targets.Target;
        var alive = selected is not Dalamud.Game.ClientState.Objects.Types.ICharacter character || !character.IsDead;
        var encounterAlive = encounterActor == 0 || objects.Any(o => o.GameObjectId == encounterActor && IsEnemy(o));
        if (!targetBoundary.Observe(selected?.GameObjectId ?? 0, alive) && encounterAlive) return true;
        if (weave.InFlight is { } ticket && castResults.TryGetValue(ticket, out var result) && result.Accepted)
            weave.Complete(ticket, true, result.Message);
        if (weave.InFlight != null && castPlayback.Request == weave.InFlight) {
            weave.StopAfterCurrent("Target ended · Enter / > continue · . restart");
            StopFollowing("Target ended");
        } else InterruptWeave("Target ended · Enter / > continue · . restart", true);
        return false;
    }
    private void StartPlayback(bool restart = false)
    {
        if (composer.Active && composer.Target is "nearest" or "nearestmob" or "enemy" or "mob" or "boss") {
            var chosen = Resolve(composer.Target);
            if (chosen != null) targets.Target = chosen;
        }
        composer.Active = false;
        encounterActor = 0;
        targetBoundary.Start(targets.Target?.GameObjectId ?? 0);
        if (restart || weave.Finished) CancelWeaveTicket(weave.Repeat());
        else weave.Resume();
    }

    private void MovementControl()
    {
        weave.EnterControl();
        lastMotionAt = Environment.TickCount64;
        StopFollowing("Movement");
    }

    private unsafe void WeaveUpdate(IFramework _)
    {
        if (disposed) return;
        try {
            hudStartup ??= GhosttyDalamud.NativeWindows.StartupTask;
            if (hudStartup.IsFaulted) { last = "Native spell HUD failed to initialize"; return; }
            if (!hudStartup.IsCompletedSuccessfully) return;
            if (hud == null) { hudController = new OverlayController(); hud = new WeaveHud(); hudController.AddNode(hud); }
            var player = objects.LocalPlayer;
            var available = barVisible && player != null && !player.IsDead && !gameGui.GameUiHidden &&
                !conditions[Dalamud.Game.ClientState.Conditions.ConditionFlag.BetweenAreas] &&
                !conditions[Dalamud.Game.ClientState.Conditions.ConditionFlag.OccupiedInCutSceneEvent];
            hud.IsVisible = available;
            keyboard.Install();
            keyboard.Enabled = available;
            if (!available) { ReadController(false); keyboard.PollBackspace(Environment.TickCount64, false); InterruptWeave("Spellcasting suspended"); lastPlayerPosition = null; return; }
            GetWindowThreadProcessId(GetForegroundWindow(), out var foreground);
            var focused = foreground == (uint)Environment.ProcessId;
            var otherText = editorOpen || RaptureAtkModule.Instance()->IsTextInputActive() || Dalamud.Bindings.ImGui.ImGui.GetIO().WantTextInput || visible;
            keyboard.Enabled = focused && !otherText;
            keyboard.Capture = weave.InputMode;
            keyboard.PollBackspace(Environment.TickCount64, (GetAsyncKeyState(0x08) & 0x8000) != 0 &&
                (GetAsyncKeyState(0x11) & 0x8000) == 0 && (GetAsyncKeyState(0x12) & 0x8000) == 0, weave.Draft.Length > 0);
            if (!focused || otherText) {
                InterruptWeave(focused ? "Other text input" : "Game unfocused");
                while (keyboard.Events.TryDequeue(out var ignored)) { }
            } else ReadWeaveKeyboard();
            spellInputActive = weave.InputMode; otherTextInputActive = otherText;
            if (Interlocked.Exchange(ref combatFocusRequested, 0) != 0) {
                weave.EnterInput();
                if (weave.Draft.Length == 0 && weave.Paused) StartPlayback();
            }
            var now = Environment.TickCount64;
            if (lastPlayerPosition is { } pos && Vector3.DistanceSquared(player!.Position, pos) > .000001f) lastMotionAt = now;
            moving = now - lastMotionAt < 120;
            lastPlayerPosition = player!.Position;
            if (focusSpellInput) { weave.EnterInput(); focusSpellInput = false; }
            if (commandText.Length > 0) {
                if (ResolveRune(commandText) is { } choice) weave.Add(choice.Command, choice.CardId);
                commandText = "";
            }
            if (actionEffects != null) while (actionEffects.Received.TryDequeue(out var effect))
                if (effect.Caster == player.EntityId) castPlayback.Confirm(effect.Action, effect.Sequence);
            if (castPlayback.Request is { } castRequest) {
                var actionManager = ActionManager.Instance();
                var outcome = castPlayback.Poll(now, player.IsCasting, actionManager == null ? 0 : actionManager->CastActionId,
                    actionManager == null ? (ushort)0 : actionManager->LastUsedActionSequence, moving);
                if (outcome != CastPlayback.Outcome.Waiting) {
                    if (castResults.Count >= 256) castResults.Clear();
                    castResults[castRequest] = new(outcome == CastPlayback.Outcome.Completed,
                        outcome == CastPlayback.Outcome.MovementInterrupted,
                        outcome == CastPlayback.Outcome.Completed ? "Cast confirmed" : outcome == CastPlayback.Outcome.MovementInterrupted ? "Relocating · retrying this step" : "Cast outcome unknown · > to retry");
                    castPlayback.Reset();
                }
            }
            if (!weave.Paused && (weave.InFlight != null || !weave.Finished)) CheckEncounterTarget();
            ReadController(focused && !otherText);
            if (focused && !otherText && !composer.Active && now >= retryAt && (GetAsyncKeyState(0x08) & 0x8000) == 0 && Environment.TickCount64 - lastRuntimePoll < 3000 && !player.IsCasting && weave.Next is { } next) {
                var card = cards.FirstOrDefault(c => c.Id == next.CardId);
                var ready = false;
                var manager = ActionManager.Instance();
                if (armed && manager != null && card != null) {
                    // A Lua sequence chooses its actual action and target at invocation time.
                    if (card.Source.Contains("ctx:sequence(") || next.Command.StartsWith("if ", StringComparison.OrdinalIgnoreCase) || next.Command.StartsWith("on ", StringComparison.OrdinalIgnoreCase)) ready = true;
                    else if (Resolve(card.Target) is { } target) {
                        ready = manager->GetActionStatus(ActionType.Action, manager->GetAdjustedActionId(card.Action), target.GameObjectId) == 0;
                        if (!ready) weave.Hint = "Readying " + card.Name;
                    } else weave.Hint = "Select a valid " + card.Target + " target";
                }
                if (ready && moving && card != null && ActionManager.GetAdjustedCastTime(ActionType.Action, manager->GetAdjustedActionId(card.Action), true) > 0 &&
                    !card.Source.Contains("ctx:sequence(") && !next.Command.StartsWith("if ", StringComparison.OrdinalIgnoreCase)) {
                    ready = false; weave.Hint = "Relocating · waiting for stillness";
                }
                if (ready) {
                    var request = "weave-" + Guid.NewGuid().ToString("N");
                    weave.Begin(request); weaveSentAt = Environment.TickCount64; CardInput(next.Command, "command", requestId: request);
                }
            }
            // A lost result is an unknown outcome: retain the cursor and require explicit continuation.
            if (weave.InFlight != null && (Environment.TickCount64 - weaveSentAt > 35000 || Environment.TickCount64 - lastRuntimePoll >= 3000)) InterruptWeave("Spellbook disconnected");
            hud.Render(weave, cards, data, armed, Environment.TickCount64 - lastRuntimePoll < 3000, conditions[Dalamud.Game.ClientState.Conditions.ConditionFlag.InCombat], RuneTarget, ReadCooldown, composer);
        } catch (Exception ex) { log.Error(ex, "Spell weave update"); InterruptWeave("Weave paused"); }
    }

    private void ReadWeaveKeyboard()
    {
        while (keyboard.Events.TryDequeue(out var input)) {
            switch (input.Type) {
                case SpellKeyboard.Kind.Escape: CardInput("cancel", "voice"); composer.Active = false; InterruptWeave("Interrupted", true); break;
                case SpellKeyboard.Kind.Movement: MovementControl(); break;
                case SpellKeyboard.Kind.Input: weave.EnterInput(); break;
                case SpellKeyboard.Kind.Backspace: CancelWeaveTicket(weave.Backspace()); break;
                case SpellKeyboard.Kind.TextBackspace:
                    if (weave.Draft.Length > 0) weave.Backspace();
                    break;
                case SpellKeyboard.Kind.ClearLine:
                    if (weave.Draft.Length > 0) break;
                    CancelWeaveTicket(weave.ClearLine());
                    StopFollowing("Weave cleared");
                    break;
                case SpellKeyboard.Kind.Commit:
                    if (weave.Draft.Length == 0) { StartPlayback(); break; }
                    if (weave.Draft.Length > 0) {
                        if (weave.Draft.StartsWith(':')) {
                            var text = weave.Draft.Trim();
                            if (EditorTileCommand(text)) { weave.ClearDraft(); break; }
                            if (text is ":ls" or ":spells") { visible = true; weave.ClearDraft(); break; }
                            if (text == ":boss") { MarkBoss(); weave.ClearDraft(); break; }
                            if (text == ":unboss") { bossTarget = 0; weave.ClearDraft(); weave.Hint = "Boss marker cleared"; break; }
                            if (text == ":clear") { CancelWeaveTicket(weave.ClearLine()); StopFollowing("Weave cleared"); break; }
                            if (text == ":help") { weave.ClearDraft(); weave.Hint = ":e SPELL · :w · :wq · :q · :ls · :reload · :clear"; break; }
                            CardInput(text, "editor");
                            weave.ClearDraft(); weave.Hint = "Editor: " + text;
                            break;
                        }
                        SubmitDraft();
                    }
                    break;
                case SpellKeyboard.Kind.Complete:
                    if (weave.Draft.StartsWith(':')) {
                        var split = weave.Draft.IndexOf(' ');
                        if (split > 0 && weave.Draft[..split] is ":e" or ":edit") {
                            var query = Normalize(weave.Draft[(split + 1)..]);
                            var choices = cards.Where(c => c.Id.StartsWith(query, StringComparison.OrdinalIgnoreCase) || c.Phrase.StartsWith(query, StringComparison.OrdinalIgnoreCase)).ToArray();
                            if (choices.Length == 1) weave.SetDraft(weave.Draft[..(split + 1)] + choices[0].Id);
                            else weave.Hint = "Spells: " + string.Join(", ", choices.Take(4).Select(c => c.Id));
                        } else {
                            var choices = new[] { ":e ", ":w", ":wq", ":q", ":ls", ":reload", ":clear", ":boss", ":unboss", ":help" }.Where(c => c.StartsWith(weave.Draft, StringComparison.OrdinalIgnoreCase)).ToArray();
                            if (choices.Length == 1) weave.SetDraft(choices[0]);
                            else weave.Hint = string.Join(" · ", choices);
                        }
                        break;
                    }
                    var bodyStart = Math.Max(weave.Draft.LastIndexOf(" then ", StringComparison.OrdinalIgnoreCase) + 6, weave.Draft.LastIndexOf(" else ", StringComparison.OrdinalIgnoreCase) + 6);
                    if (bodyStart == 5) bodyStart = 0;
                    var targeting = ExplicitTarget.Match(weave.Draft[bodyStart..]);
                    if (targeting.Success) bodyStart += targeting.Length;
                    var prefix = Normalize(weave.Draft[bodyStart..]);
                    var matches = cards.Where(c => c.Phrase.StartsWith(prefix, StringComparison.OrdinalIgnoreCase) || c.Id.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)).ToArray();
                    if (prefix.Length > 0 && matches.Length == 1) {
                        if (bodyStart > 0) weave.SetDraft(weave.Draft[..bodyStart] + matches[0].Phrase);
                        else weave.Add(matches[0].Phrase, matches[0].Id);
                    }
                    break;
                case SpellKeyboard.Kind.Character:
                    if (input.Character == '.' && weave.Draft.Length == 0) StartPlayback(true);
                    else if (input.Character == '>' && weave.Draft.Length == 0) StartPlayback();
                    else weave.Append(input.Character, ResolveRune);
                    break;
            }
        }
        // The game's hotkey table is separate from WM_CHAR. Suppress only owned keys.
        var modified = (GetAsyncKeyState(0x11) & 0x8000) != 0 || (GetAsyncKeyState(0x12) & 0x8000) != 0;
        if (!modified) for (var key = 0; key < 256; key++) {
            var owned = weave.InputMode && (key is >= 0x30 and <= 0x5A || key is >= 0xBA and <= 0xE2 || key is 0x20 or 0x08 or 0x09 or 0x0D) || key == 0xBE;
            if (owned && keys.IsVirtualKeyValid(key)) keys[key] = false;
            if (!owned && (GetAsyncKeyState(key) & 0x8000) != 0 && (key is >= 0x25 and <= 0x28 || (!weave.InputMode && key is 0x57 or 0x41 or 0x53 or 0x44))) MovementControl();
        }
        keyboard.Capture = weave.InputMode;
    }

}

internal sealed class WeaveHud : OverlayNode
{
    public override bool HideWithNativeUi => true;
    public override bool HideWithUiToggled => true;
    public override OverlayLayer OverlayLayer => OverlayLayer.AboveUserInterface;
    protected override void OnUpdate() { }
    private readonly ColorImageNode headerLeft, headerRight;
    private readonly ColorImageNode[] links = new ColorImageNode[31];
    private readonly TextNode leftOverflow, rightOverflow;
    private float lineWidth = 560, lineScroll;
    private readonly TextNode title;
    private readonly TextNode letters;
    private readonly TextNode hint;
    private readonly TextNode rule;
    private readonly TextNode controls;
    private readonly TextNode targetLine;
    private readonly TextNode logicLine;
    private readonly TextNode editorCommands, editorMore;
    private readonly TextNode[] spellNames = new TextNode[32];
    private readonly IconImageNode[] icons = new IconImageNode[32];
    private readonly TextNode[] halos = new TextNode[32];
    private readonly TextNode[] indices = new TextNode[32];
    private readonly TextNode[] names = new TextNode[32];
    private readonly TextNode[] counts = new TextNode[32];
    private readonly TextNode[] cooldowns = new TextNode[32];
    private readonly TextNode[] progress = new TextNode[32];
    private readonly IconImageNode[] wheelIcons = new IconImageNode[8];
    private readonly TextNode[] wheelNames = new TextNode[8];
    private readonly TextNode wheelCenter, wheelCondition, wheelControls, wheelActions;
    private float controllerMorph;
    private readonly List<RuneStack> stacks = new(32);
    private string lastLogic = "";
    private long logicAt;
    private readonly uint[] runeIcons = new uint[32];
    private readonly uint[] wheelIconIds = new uint[8];
    private static readonly Vector4 Gold = new(1, .89f, .61f, 1);
    private static readonly Vector4 Ice = new(.82f, .97f, 1, 1);
    private float opacity = .82f;

    public WeaveHud()
    {
        Size = new(360, 240);
        headerLeft = new ColorImageNode { Color = Gold, Alpha = .8f, IsVisible = true };
        headerRight = new ColorImageNode { Color = Gold, Alpha = .8f, IsVisible = true };
        headerLeft.AttachNode(this, NodePosition.AsLastChild);
        headerRight.AttachNode(this, NodePosition.AsLastChild);
        title = Text(15, Gold, new(0, 0), new(360, 20));
        rule = Text(14, Gold, new(0, 17), new(360, 20)); rule.String = "─── ◇ ─────────────────── ◇ ───";
        letters = Text(23, Ice, new(8, 45), new(340, 34));
        hint = Text(14, new(.9f, .95f, 1, 1), new(8, 80), new(350, 18));
        controls = Text(12, new(.87f, .92f, 1, 1), new(8, 98), new(350, 18));
        targetLine = Text(14, Ice, new(8, 112), new(350, 18));
        logicLine = Text(14, Gold, new(8, 130), new(350, 20));
        editorCommands = Text(12, Gold, new(), new(550, 24));
        editorMore = Text(12, Ice, new(), new(550, 24));
        leftOverflow = Text(11, Gold, new(), new(60, 18));
        rightOverflow = Text(11, Gold, new(), new(60, 18));
        for (var i = 0; i < links.Length; i++) {
            links[i] = new ColorImageNode { Size = new(48, 1), Color = new(.75f, .65f, .4f, 1), IsVisible = false };
            links[i].AttachNode(this, NodePosition.AsLastChild);
        }
        for (var i = 0; i < icons.Length; i++) {
            halos[i] = Text(54, Gold, new(), new(70, 74)); halos[i].String = "◇";
            icons[i] = new IconImageNode { Size = new(42, 42), IsVisible = false };
            icons[i].AttachNode(this, NodePosition.AsLastChild);
            indices[i] = Text(13, Ice, new(), new(96, 22));
            spellNames[i] = Text(13, Gold, new(), new(104, 22));
            names[i] = Text(12, Ice, new(), new(104, 22));
            counts[i] = Text(16, Gold, new(), new(48, 24));
            cooldowns[i] = Text(13, Ice, new(), new(100, 22));
            progress[i] = Text(10, Gold, new(), new(96, 16));
        }
        for (var i = 0; i < 8; i++) {
            wheelIcons[i] = new IconImageNode { Size = new(42, 42), IsVisible = false };
            wheelIcons[i].AttachNode(this, NodePosition.AsLastChild);
            wheelNames[i] = Text(13, Gold, new(), new(116, 24));
        }
        wheelCenter = Text(15, Ice, new(126, 112), new(150, 22));
        wheelCondition = Text(12, Gold, new(88, 137), new(210, 32));
        wheelControls = Text(12, Ice, new(8, 264), new(350, 18));
        wheelActions = Text(12, Ice, new(8, 286), new(350, 18));
    }
    private TextNode Text(uint size, Vector4 color, Vector2 position, Vector2 dimensions)
    {
        var node = new TextNode { Position = position, Size = dimensions, FontSize = size,
            TextColor = color, TextOutlineColor = new(0, 0, .015f, 1), TextFlags = TextFlags.Edge | TextFlags.Bold, IsVisible = true };
        node.AttachNode(this, NodePosition.AsLastChild); return node;
    }
    private void RenderWheel(ControllerComposer composer, Card[] cards, IDataManager data, float morph, float width)
    {
        var show = morph > .02f;
        wheelCenter.IsVisible = wheelCondition.IsVisible = wheelControls.IsVisible = wheelActions.IsVisible = show;
        wheelCenter.Alpha = wheelCondition.Alpha = wheelControls.Alpha = wheelActions.Alpha = morph;
        var origin = new Vector2((width - 360) / 2, 0);
        wheelCenter.Position = new Vector2(126, 112) + origin;
        wheelCondition.Position = new Vector2(88, 137) + origin;
        wheelControls.Position = new Vector2(8, 264) + origin;
        wheelActions.Position = new Vector2(8, 286) + origin;
        wheelCenter.String = "◇ " + WeavePresentation.TargetLabel(composer.Target);
        wheelCondition.String = composer.Condition.Length == 0 ? "Unconditional" : WeavePresentation.Clip(WeavePresentation.Logic("if " + composer.Condition), 32);
        wheelControls.String = "← → spell · ↑ ↓ target · L1/R1 condition";
        wheelActions.String = "A / × weave · X / □ erase · Y / △ microphone";
        for (var i = 0; i < 8; i++) {
            wheelIcons[i].IsVisible = wheelNames[i].IsVisible = show && cards.Length > 0;
            if (cards.Length == 0) continue;
            var card = cards[(Math.Clamp(composer.CardIndex, 0, cards.Length - 1) + i) % cards.Length];
            var angle = -MathF.PI / 2 + i * MathF.Tau / 8;
            var orbit = new Vector2(165 + MathF.Cos(angle) * 115, 118 + MathF.Sin(angle) * 74);
            wheelIcons[i].Position = Vector2.Lerp(new(165, 118), orbit, morph) + origin;
            wheelIcons[i].Alpha = morph * (i == 0 ? 1 : .9f);
            wheelIcons[i].Scale = new(i == 0 ? 1.25f : 1);
            var appearance = SpellAppearance.Resolve(data, card);
            wheelIcons[i].IsVisible = show && appearance != null;
            if (appearance is { } visual && wheelIconIds[i] != visual.Icon) { wheelIcons[i].IconId = visual.Icon; wheelIconIds[i] = visual.Icon; }
            wheelNames[i].Position = wheelIcons[i].Position + new Vector2(-20, 44);
            wheelNames[i].String = WeavePresentation.Clip(appearance?.Name ?? card.Name, 15);
            wheelNames[i].Alpha = morph * (i == 0 ? 1 : .9f);
        }
    }
    public void Render(SpellWeave weave, Card[] cards, IDataManager data, bool live, bool online, bool inCombat, Func<SpellWeave.Rune, int, RuneTarget> target, Func<SpellWeave.Rune, int, SpellTiming> timing, ControllerComposer composer)
    {
        var recovery = weave.InFlight == null && !weave.Paused && weave.Cursor > 0 && weave.Next is { } next && timing(next, weave.Cursor).Remaining > .05f;
        var playing = weave.InFlight != null || recovery;
        var viewport = Dalamud.Bindings.ImGui.ImGui.GetMainViewport();
        WeavePresentation.Fill(stacks, weave, target);
        const float spacing = 104;
        var maximumWidth = MathF.Max(240, MathF.Min(1200, viewport.Size.X - 64));
        var wantedWidth = Math.Clamp(stacks.Count * spacing + 48, MathF.Min(560, maximumWidth), maximumWidth);
        lineWidth += (wantedWidth - lineWidth) * .2f;
        lineWidth = MathF.Min(lineWidth, maximumWidth);
        var focus = stacks.FindIndex(s => s.Contains(weave.Cursor));
        if (focus < 0 || (composer.Active || weave.InputMode) && !playing) focus = stacks.Count - 1;
        var maximumScroll = MathF.Max(0, (stacks.Count - 1) * spacing + 112 - lineWidth);
        var wantedScroll = Math.Clamp(32 + Math.Max(0, focus) * spacing - (lineWidth - 80) * .4f, 0, maximumScroll);
        lineScroll += (wantedScroll - lineScroll) * .2f;
        lineScroll = Math.Clamp(lineScroll, 0, maximumScroll);
        controllerMorph += ((composer.Active ? 1 : 0) - controllerMorph) * .22f;
        var wheelHeight = controllerMorph * 320;
        var lineHeight = stacks.Count == 0 ? 0 : 164;
        var panelHeight = 40 + lineHeight + 220 + wheelHeight;
        Size = new(lineWidth, panelHeight);
        title.Size = rule.Size = new(lineWidth, 26);
        letters.Size = new(lineWidth - 24, 34);
        hint.Size = controls.Size = targetLine.Size = new(lineWidth - 24, 24);
        logicLine.Size = new(lineWidth - 24, 26);
        editorCommands.Size = editorMore.Size = new(lineWidth - 24, 24);
        rule.String = "◇";
        rule.Position = new(lineWidth / 2 - 7, 25);
        headerLeft.Position = new(0, 34);
        headerRight.Position = new(lineWidth / 2 + 14, 34);
        headerLeft.Size = headerRight.Size = new(lineWidth / 2 - 14, 2);
        leftOverflow.Position = new(8, 39 + wheelHeight);
        rightOverflow.Position = new(lineWidth - 55, 39 + wheelHeight);
        Position = new((viewport.Size.X - lineWidth) / 2, MathF.Max(16, MathF.Min(viewport.Size.Y * .72f, viewport.Size.Y - panelHeight - 16)));
        // Read the native screen bounds without claiming mouse input. Hover
        // brightens content only; there is no backing rectangle behind it.
        var bounds = Bounds;
        var hovered = Dalamud.Bindings.ImGui.ImGui.IsMouseHoveringRect(bounds.TopLeft, bounds.BottomRight, false);
        var wantedOpacity = composer.Active || playing || weave.InputMode ? 1f : hovered ? .99f : inCombat ? .95f : .82f;
        opacity += (wantedOpacity - opacity) * .3f;
        if (composer.Active || playing) opacity = 1;
        else if (hovered) opacity = Math.Max(opacity, .99f);
        else if (inCombat) opacity = Math.Max(opacity, .95f);
        Alpha = opacity;
        var now = Environment.TickCount64;
        title.String = $"G R I M O I R E   /   {(composer.Active ? "WEAVE ◇ CONTROLLER" : weave.InputMode ? "WEAVE" : "CONTROL")}";
        RenderWheel(composer, cards, data, controllerMorph, lineWidth);
        title.TextColor = weave.Paused || !live ? Gold : Ice;
        var hiddenLeft = 0; var hiddenRight = 0;
        for (var i = 0; i < links.Length; i++) links[i].IsVisible = false;
        for (var i = 0; i < icons.Length; i++) {
            var x = 32 + i * spacing - lineScroll;
            var show = i < stacks.Count && x >= 24 && x <= lineWidth - 80;
            if (i < stacks.Count && !show) { if (x < 24) hiddenLeft++; else hiddenRight++; }
            icons[i].IsVisible = halos[i].IsVisible = indices[i].IsVisible = spellNames[i].IsVisible = names[i].IsVisible = counts[i].IsVisible = cooldowns[i].IsVisible = progress[i].IsVisible = show;
            if (!show) continue;
            var stack = stacks[i];
            var current = stack.Contains(weave.Cursor);
            var rune = current ? weave.Runes[weave.Cursor] : stack.Rune;
            var card = cards.FirstOrDefault(c => c.Id == rune.CardId);
            var appearance = SpellAppearance.Resolve(data, card, rune.PlayedAction);
            icons[i].IsVisible = appearance != null;
            if (appearance is { } visual && runeIcons[i] != visual.Icon) { icons[i].IconId = visual.Icon; runeIcons[i] = visual.Icon; }
            var age = Math.Clamp((now - rune.Created) / 280f, 0, 1);
            var pop = 1 + .18f * MathF.Sin(age * MathF.PI);
            var active = current && weave.InFlight != null || recovery && stack.Contains(weave.Cursor - 1);
            var completed = stack.Completed(weave.Cursor) && !active;
            var pulse = .5f + .5f * MathF.Sin(now / 135f);
            var p = new Vector2(x, 80 + wheelHeight - (1 - age) * 10);
            if (i < links.Length && i + 1 < stacks.Count && x + spacing <= lineWidth - 80) {
                links[i].IsVisible = true;
                links[i].Position = p + new Vector2(48, 21);
                links[i].Alpha = completed ? .2f : active ? 1 : .7f;
            }
            icons[i].Position = p; icons[i].Scale = new(active ? 1.12f + .04f * pulse : pop);
            icons[i].Alpha = completed ? .35f : 1;
            halos[i].Position = p + new Vector2(-12, -17);
            halos[i].String = active ? "✦" : "◇";
            halos[i].Scale = new(active ? 1.08f + .08f * pulse : 1);
            halos[i].TextColor = active ? new Vector4(.82f, .96f, 1, 1) : current ? (weave.Paused ? Gold : Ice) : Gold;
            halos[i].Alpha = active ? 1 : current ? .65f + .3f * MathF.Sin(now / 180f) : completed ? .12f : .5f;
            var badge = target(rune, current ? weave.Cursor : stack.Start);
            indices[i].Position = p + new Vector2(-6, -20);
            indices[i].String = WeavePresentation.Clip(WeavePresentation.TargetLabel(badge.Selector), 11);
            indices[i].Alpha = completed ? .3f : 1;
            spellNames[i].Position = p + new Vector2(-12, 46);
            spellNames[i].String = WeavePresentation.Clip(appearance?.Name ?? card?.Name ?? rune.CardId, 14);
            spellNames[i].Alpha = completed ? .35f : 1;
            names[i].Position = p + new Vector2(-12, 66);
            names[i].String = WeavePresentation.Clip(badge.Name, 13);
            names[i].Alpha = completed ? .3f : 1;
            counts[i].Position = p + new Vector2(34, 30);
            counts[i].String = stack.Count > 1 ? "×" + stack.DisplayCount(weave.Cursor) : "";
            counts[i].Alpha = stack.Completed(weave.Cursor) ? .3f : 1;
            var clock = timing(rune, current ? weave.Cursor : stack.Start);
            if (active && recovery && weave.Next is { } waiting) clock = timing(waiting, weave.Cursor);
            cooldowns[i].Position = p + new Vector2(-8, 86);
            cooldowns[i].String = clock.Label;
            cooldowns[i].Alpha = completed ? .35f : 1;
            progress[i].Position = p + new Vector2(-8, 104);
            var filled = (int)MathF.Round(clock.Progress * 7);
            progress[i].String = clock.Remaining > .05f ? new string('━', filled) + new string('─', 7 - filled) : "";
            progress[i].Alpha = completed ? .3f : 1;
        }
        leftOverflow.IsVisible = hiddenLeft > 0;
        rightOverflow.IsVisible = hiddenRight > 0;
        leftOverflow.String = "‹ " + hiddenLeft;
        rightOverflow.String = hiddenRight + " ›";
        var y = 46 + wheelHeight + lineHeight;
        var textLimit = Math.Max(20, (int)((lineWidth - 24) / 8f));
        var selected = weave.Cursor < weave.Runes.Count ? weave.Cursor : weave.Runes.Count - 1;
        string logic = weave.Draft;
        if (selected >= 0) {
            var rune = weave.Runes[selected]; var badge = target(rune, selected);
            var group = stacks.FirstOrDefault(s => s.Contains(selected));
            var step = group.Count > 1 ? $" · {selected - group.Start + 1}/{group.Count}" : "";
            var card = cards.FirstOrDefault(c => c.Id == rune.CardId);
            var appearance = SpellAppearance.Resolve(data, card, rune.PlayedAction);
            targetLine.String = WeavePresentation.Clip((appearance?.Name ?? card?.Name ?? rune.CardId) + " → " + badge.Name + " [" + WeavePresentation.TargetLabel(badge.Selector) + "]" + step, textLimit);
            if (logic.Length == 0) logic = rune.Command;
            if (weave.Draft.Length == 0 && rune.ConditionResult is bool outcome)
                logic = (outcome ? "✓ " : "◇ ") + logic;
        } else targetLine.String = "";
        targetLine.Position = new(8, y); y += 24;
        if (logic != lastLogic) { lastLogic = logic; logicAt = now; }
        var glow = Math.Clamp(1 - (now - logicAt) / 700f, 0, 1);
        logicLine.IsVisible = WeavePresentation.HasLogic(logic);
        logicLine.String = WeavePresentation.Clip(WeavePresentation.Logic(logic), textLimit);
        logicLine.Position = new(8, y - glow * 2);
        logicLine.Scale = new(1 + glow * .025f);
        var spentLogic = weave.Draft.Length == 0 && selected >= 0 && selected < weave.Cursor;
        logicLine.Alpha = spentLogic ? .3f : hovered || inCombat || playing ? 1 : weave.InputMode ? .9f + glow * .1f : .9f;
        targetLine.Alpha = spentLogic ? .3f : 1;
        logicLine.TextColor = new(1, .78f + glow * .2f, .38f + glow * .35f, 1);
        if (logicLine.IsVisible) y += 30;
        letters.Position = new(8, y);
        letters.FontSize = weave.Draft.Length * 12 > lineWidth - 32 ? 16u : 23u;
        var draftLimit = Math.Max(16, (int)((lineWidth - 32) / (letters.FontSize * .55f)));
        letters.String = weave.Draft.Length > 0 ? (weave.Draft.Length > draftLimit ? "…" + weave.Draft[^(draftLimit - 1)..] : weave.Draft) + "│" : weave.InputMode ? "◇  weave a spell" : "◇";
        letters.Alpha = weave.Draft.Length > 0 ? 1 : .45f;
        hint.Position = new(8, y + 40);
        var message = !online ? "Spellbook disconnected" : !live ? "Disarmed · /xivspell input enables casting" : weave.Hint;
        hint.String = WeavePresentation.Clip(message, textLimit);
        controls.Position = new(8, y + 64);
        editorCommands.Position = new(8, y + 88);
        editorMore.Position = new(8, y + 112);
        editorCommands.String = ":e SPELL edit · :w save · :wq save+close · :q close";
        editorMore.String = ":ls book · :reload · :clear · :boss / :unboss · :help";
        controls.String = composer.Active ? "L3+R3 close · Start continue · Select restart" : weave.InputMode ? "ESC control · Enter line · hold Backspace clear" : "I weave · . restart · > / Enter continue · L3+R3 pad";
    }
}
