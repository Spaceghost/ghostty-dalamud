using System.Net;
using System.Net.Sockets;
using System.Numerics;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Dalamud.Bindings.ImGui;
using Dalamud.Configuration;
using Dalamud.Game.Command;
using Dalamud.Game.ClientState.Conditions;
using Dalamud.Game.ClientState.Objects.Types;
using Dalamud.Plugin;
using Dalamud.Plugin.Services;
using FFXIVClientStructs.FFXIV.Client.Game;
using FFXIVClientStructs.FFXIV.Client.System.String;
using FFXIVClientStructs.FFXIV.Client.UI;
using ActionRow = Lumina.Excel.Sheets.Action;

namespace XivSpell;

[Serializable]
public sealed class Config : IPluginConfiguration
{
    public int Version { get; set; } = 1;
    public SpellWeave.SavedState? Weave { get; set; }
    public string EditorCard { get; set; } = "";
    public string EditorSource { get; set; } = "";
    public string EditorOriginal { get; set; } = "";
    public bool EditorOpen { get; set; }
    public string Token { get; set; } = Convert.ToHexString(RandomNumberGenerator.GetBytes(32));
}

public sealed record Card(string Id, string Name, uint Action, string Target, string Phrase, string Source = "", string[]? Aliases = null);
public sealed record CardEvent(long Sequence, string Card, string Kind, long Time, double Seconds, string RequestId);

internal sealed partial class Plugin : IDisposable
{
    private readonly IDalamudPluginInterface pi;
    private readonly ICommandManager commands;
    private readonly IFramework framework;
    private readonly IObjectTable objects;
    private readonly ITargetManager targets;
    private readonly IPartyList party;
    private readonly ICondition conditions;
    private readonly IDataManager data;
    private readonly ITextureProvider textures;
    private readonly IPluginLog log;
    private readonly IGamepadState gamepad;
    private readonly IKeyState keys;
    private readonly IClientState client;
    private readonly NativeChatSuppression nativeChat = new();
    private readonly Config config;
    private readonly TcpListener listener = new(IPAddress.Loopback, 41806);
    private readonly CancellationTokenSource shutdown = new();
    private readonly IDisposable ipc;
    private readonly object recentLock = new();
    private readonly Dictionary<string, object> recent = new();
    private bool visible;
    private bool armed = true;
    private bool following;
    private string last = "Tab completes  ·  . repeats";
    private Card[] cards = [];
    private readonly Queue<CardEvent> cardEvents = new();
    private long eventSequence;
    private readonly string runtimeSession = Guid.NewGuid().ToString("N");
    private readonly Dictionary<string, object> commandResults = new();
    private static readonly JsonSerializerOptions Json = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, PropertyNameCaseInsensitive = true };

    public Plugin(IDalamudPluginInterface pi, ICommandManager commands, IFramework framework,
        IObjectTable objects, ITargetManager targets, IPartyList party, ICondition conditions,
        IDataManager data, ITextureProvider textures, IPluginLog log, IGamepadState gamepad, IKeyState keys, IGameGui gameGui, IClientState client, IGameInteropProvider interop)
    {
        this.pi = pi; this.commands = commands; this.framework = framework; this.objects = objects;
        this.targets = targets; this.party = party; this.conditions = conditions; this.data = data;
        this.textures = textures; this.log = log;
        this.gamepad = gamepad; this.keys = keys; this.gameGui = gameGui;
        this.client = client;
        actionEffects = new ActionEffects(interop);
        try { pad = new GrimoirePad(interop); } catch (Exception ex) { log.Warning(ex, "Grimoire controller capture unavailable"); }
        config = GhosttyDalamud.PhoneModules.ModuleConfiguration.Load<Config>(pi, "Grimoire");
        weave.Restore(config.Weave);
        editorCard = config.EditorCard; editorSource = config.EditorSource; editorSavedSource = config.EditorOriginal;
        editorOpen = config.EditorOpen && editorCard.Length > 0;
        GhosttyDalamud.PhoneModules.ModuleConfiguration.Save(pi, "Grimoire", config);
        commands.AddHandler("/xivspell", new CommandInfo((_, args) => {
            if (args == "off") { InterruptWeave("Disarmed", true); armed = false; StopFollowing("Disarmed"); }
            else if (args.StartsWith(':') && EditorTileCommand(args)) { }
            else if (args.StartsWith("edit ", StringComparison.OrdinalIgnoreCase)) OpenSpellEditor(args[5..].Trim());
            else if (args == "pad") { composer.Active = !composer.Active; if (composer.Active) InterruptWeave("Controller composing", true); }
            else if (args == "voice") CardInput("toggle", "voice");
            else if (args == "cards") visible = !visible;
            else if (args == "book") visible = true;
            else if (args == "clear") { CancelWeaveTicket(weave.ClearLine()); StopFollowing("Weave cleared"); }
            else if (args == "input") { armed = true; barVisible = true; focusSpellInput = true; }
            else { barVisible = !barVisible; if (!barVisible) InterruptWeave("Hidden", true); }
        }) { HelpMessage = "Toggle Grimoire. input focuses it; cards opens Lua cards; clear clears the weave; off disarms. Backspace deletes; hold to clear." });
        pi.UiBuilder.Draw += Draw;
        
        
        framework.Update += FollowUpdate;
        framework.Update += WeaveUpdate;
        framework.Update += InputUpdate;
        var gate = pi.GetIpcProvider<string, string>("XivSpell.Call");
        gate.RegisterFunc(input => Serialize(Dispatch(JsonSerializer.Deserialize<Request>(input, Json) ?? new())));
        ipc = new Cleanup(gate.UnregisterFunc);
        listener.Start(8);
        _ = Serve();
    }

    private void Open() { barVisible = true; focusSpellInput = true; }
    private static string Serialize(object value) => JsonSerializer.Serialize(value, Json);
    public sealed class Request
    {
        public string Method { get; set; } = "snapshot";
        public uint Action { get; set; }
        public string Target { get; set; } = "current";
        public string RequestId { get; set; } = "";
        public Card[]? Cards { get; set; }
        public float Range { get; set; } = 15;
        public long After { get; set; }
        public Dictionary<string, string>? Expansions { get; set; }
        public string Text { get; set; } = "";
        public bool? Accepted { get; set; }
        public string Mode { get; set; } = "";
        public string CardId { get; set; } = "";
        public bool? Condition { get; set; }
        public bool Skipped { get; set; }
        public bool Retry { get; set; }
        public long Revision { get; set; }
    }

    private IGameObject? Resolve(string target) => target switch {
        "current" => targets.Target,
        "self" => objects.LocalPlayer,
        "focus" => targets.FocusTarget,
        "targetOfTarget" => targets.Target == null ? null : objects.FirstOrDefault(o => o.EntityId == targets.Target.TargetObjectId),
        "role" => ResolveRoleTarget(),
        "enemy" => ResolveEnemy(false),
        "nearest" => ResolveEnemy(false, true),
        "nearestmob" => ResolveEnemy(true, true),
        "mob" => ResolveEnemy(true),
        "boss" => objects.FirstOrDefault(o => o.GameObjectId == bossTarget && IsEnemy(o)),
        "ally" => party.Any(p => p.GameObject?.GameObjectId == targets.Target?.GameObjectId) ? targets.Target : Resolve("lowest"),
        "lowest" => party.Select(p => p.GameObject).OfType<ICharacter>().Where(p => p.MaxHp > 0 && p.CurrentHp > 0).OrderBy(p => (double)p.CurrentHp / p.MaxHp).FirstOrDefault() ?? objects.LocalPlayer,
        _ when target.StartsWith("name:", StringComparison.OrdinalIgnoreCase) => ResolveNamedTarget(target[5..]),
        _ when target.StartsWith("tank") || target.StartsWith("healer") || target.StartsWith("dps") || target.StartsWith("melee") || target.StartsWith("ranged") => ResolvePartyRole(target),
        _ when target.StartsWith("party") && int.TryParse(target.AsSpan(5), out var n) && n >= 1 && n <= party.Length => party[n - 1]?.GameObject,
        _ => null,
    };

    private IGameObject? ResolveNamedTarget(string name)
    {
        if (targets.Target is { } selected && string.Equals(selected.Name.TextValue, name, StringComparison.OrdinalIgnoreCase)) return selected;
        var matches = objects.Where(o => o.IsTargetable && string.Equals(o.Name.TextValue, name, StringComparison.OrdinalIgnoreCase)).Take(2).ToArray();
        if (matches.Length > 1) throw new InvalidOperationException("Several targets named " + name + "; select one with Tab or use a party slot");
        return matches.FirstOrDefault();
    }

    private unsafe object Dispatch(Request r)
    {
        if (r.Method is "compiled" or "translated") {
            if (r.RequestId != draftRequest || weave.DraftRevision != draftRequestRevision || !weave.InputMode) return new { discarded = true };
            draftRequest = null;
            if (r.Accepted != true) { weave.Hint = r.Text.Length > 200 ? r.Text[..200] : r.Text; return new { ok = false }; }
            if (r.Text.Length is < 1 or > 255 || !cards.Any(c => c.Id == r.CardId)) throw new InvalidOperationException("Invalid compiled spell line");
            if (r.Method == "translated") { weave.SetDraft(r.Text); weave.Hint = "Local suggestion · Enter to weave"; }
            else weave.Add(r.Text, r.CardId);
            return new { ok = true, preview = r.Method == "translated" };
        }
        if (r.Method == "editor_open") { OpenSpellEditor(r.CardId); return new { ok = editorOpen }; }
        if (r.Method == "editor_command") return new { ok = EditorTileCommand(r.Text), message = editorMessage };
        if (r.Method == "editor_result") {
            if (r.RequestId != editorTicket || !editorSaving) return new { discarded = true };
            editorSaving = false; editorMessage = r.Text;
            if (r.Accepted == true) {
                editorSavedSource = editorSubmittedSource;
                if (editorCloseAfterSave && !editorDirty) editorOpen = false;
                else if (editorDirty) editorMessage += " · newer edits remain unsaved";
            }
            return new { ok = true };
        }
        if (r.Method == "visuals") return cards.Select(c => new { c.Id, cardName = c.Name, visual = SpellAppearance.Resolve(data, c) }).ToArray();
        if (r.Method == "speech_state") {
            if (r.After != speechGeneration && r.Mode == "listening") { speechGeneration = r.After; speechRevision = weave.DraftRevision; }
            weave.Hint = r.Text.Length > 160 ? r.Text[..160] : r.Text;
            return new { revision = speechRevision };
        }
        if (r.Method == "speech") {
            if (r.After != speechGeneration || r.Revision != weave.DraftRevision || r.Revision != speechRevision) {
                weave.Hint = "Speech discarded · input changed while recording";
                return new { discarded = true };
            }
            if (r.Text.Length is <1 or >255 || r.Text.Any(char.IsControl)) throw new InvalidOperationException("Speak one spell line");
            weave.SetDraft(r.Text); weave.EnterInput();
            weave.Hint = "Speech ready · Enter / A to weave";
            return new { ok = true };
        }
        if (r.Method == "target") {
            var selected = Resolve(r.Target) ?? throw new InvalidOperationException("No living " + r.Target + " target nearby");
            targets.Target = selected;
            if (!weave.Finished || weave.InFlight != null) {
                targetBoundary.Observe(selected.GameObjectId, true);
                CheckEncounterTarget();
            }
            weave.Hint = "Target: " + selected.Name.TextValue + " · Enter / > continue";
            return new { accepted = true, message = weave.Hint };
        }
        if (r.Method == "cast_result") {
            if (castResults.TryGetValue(r.RequestId, out var outcome)) return outcome;
            if (r.RequestId == castPlayback.Request) return new { pending = true };
            return new { accepted = false, message = "Cast outcome unavailable" };
        }
        if (r.Method == "events") {
            lastRuntimePoll = Environment.TickCount64;
            var player = objects.LocalPlayer;
            return new { events = cardEvents.Where(e => e.Sequence > r.After).ToArray(), sequence = eventSequence, session = runtimeSession,
                state = new { armed, following, followTarget, message = last,
                    playerName = player?.Name.TextValue, job = player?.ClassJob.RowId, level = player?.Level,
                    role = player?.ClassJob.Value.Role, hp = player?.CurrentHp, maxHp = player?.MaxHp, mp = player?.CurrentMp,
                    isCasting = player?.IsCasting, targetId = targets.Target?.EntityId, targetName = targets.Target?.Name.TextValue,
                    focusId = targets.FocusTarget?.EntityId, focusName = targets.FocusTarget?.Name.TextValue,
                    targetHp = (targets.Target as ICharacter)?.CurrentHp, targetMaxHp = (targets.Target as ICharacter)?.MaxHp,
                    focusHp = (targets.FocusTarget as ICharacter)?.CurrentHp, focusMaxHp = (targets.FocusTarget as ICharacter)?.MaxHp,
                    maxMp = player?.MaxMp } };
        }
        if (r.Method == "feedback") {
            if (r.Mode == "editor") weave.Hint = r.Text.Length > 200 ? r.Text[..200] : r.Text;
            if (r.RequestId == weave.InFlight) {
                weave.RecordCondition(r.RequestId, r.Condition);
                if (r.Retry) { weave.Retry(r.RequestId, r.Text); retryAt = Environment.TickCount64 + 150; }
                else { weave.Complete(r.RequestId, r.Accepted == true, r.Text); if (r.Skipped) weave.Hint = r.Text; }
            }
            last = r.Text.Length > 256 ? r.Text[..256] : r.Text;
            if (r.RequestId.Length > 0) commandResults[r.RequestId] = new { state = "completed", accepted = r.Accepted, mode = r.Mode, message = last };
            return new { ok = true };
        }
        if (r.Method == "command_result") return commandResults.TryGetValue(r.RequestId, out var outcome) ? outcome : new { state = "unknown" };
        if (r.Method == "input") {
            if (string.IsNullOrWhiteSpace(r.RequestId) || string.IsNullOrWhiteSpace(r.Text) || r.Text.Length > 255) throw new InvalidOperationException("input needs requestId and 1–255 characters of spell command text");
            if (commandResults.TryGetValue(r.RequestId, out var existing)) return existing;
            if (Environment.TickCount64 - lastRuntimePoll >= 3000) throw new InvalidOperationException("Spellbook disconnected");
            CardInput(r.Text, "command", requestId: r.RequestId);
            return new { queued = true, requestId = r.RequestId };
        }
        if (r.Method == "snapshot") return new { armed, following, followTarget, followRange, last, cards, player = objects.LocalPlayer?.Name.TextValue,
            job = objects.LocalPlayer?.ClassJob.RowId, level = objects.LocalPlayer?.Level,
            target = targets.Target?.Name.TextValue, focus = targets.FocusTarget?.Name.TextValue,
            weave = new { draftRevision = weave.DraftRevision, encounterActor, selectedEncounter = targetBoundary.Target, targetStopped = targetBoundary.Stopped, composer = composer.Active, keyboardInstalled = keyboard.Installed, inputMode = weave.InputMode, paused = weave.Paused, cursor = weave.Cursor, draft = weave.Draft, runes = weave.Runes, inFlight = weave.InFlight, hint = weave.Hint },
            editor = new { open = editorOpen, card = editorCard, dirty = editorDirty, saving = editorSaving, message = editorMessage },
            controllerNavigation = gamepad.EnableGamepadNav,
            controllerLeftStick = new { x = gamepad.LeftStick.X, y = gamepad.LeftStick.Y },
            controllerButtons = Enum.GetValues<Dalamud.Game.ClientState.GamePad.GamepadButtons>().Where(button => gamepad.Raw(button) > 0).Select(button => button.ToString()).ToArray() };
        if (r.Method == "cards") {
            if (r.Cards == null || r.Cards.Length > 64) throw new InvalidOperationException("Deck must contain at most 64 cards");
            cards = r.Cards;
            expansions = r.Expansions ?? new();
            return new { ok = true, count = cards.Length, sequence = eventSequence };
        }
        if (r.Method == "disarm") { InterruptWeave("Disarmed", true); armed = false; StopFollowing("Disarmed"); return new { armed }; }
        if (r.Method == "unfollow") { StopFollowing("Follow stopped"); return new { following, message = last }; }
        if (r.RequestId.StartsWith("weave-") && (cancelledWeaves.Contains(r.RequestId) || r.RequestId != weave.InFlight)) throw new InvalidOperationException("Weave interrupted");
        if (r.Method != "cast" && r.Method != "follow" && r.Method != "unfollow") throw new InvalidOperationException("Unknown operation");
        if (!armed) throw new InvalidOperationException("Live casts disabled. Enable them in /xivspell.");
        if (objects.LocalPlayer == null || objects.LocalPlayer.IsDead || conditions[ConditionFlag.BetweenAreas] || conditions[ConditionFlag.OccupiedInCutSceneEvent])
            throw new InvalidOperationException("Player unavailable");
        if (string.IsNullOrWhiteSpace(r.RequestId)) throw new InvalidOperationException("A unique input requestId is required");
        lock (recentLock) if (recent.TryGetValue(r.RequestId, out var cached)) return cached;
        object result;
        if (r.Method == "cast") {
            if (r.RequestId == weave.InFlight && !CheckEncounterTarget()) throw new InvalidOperationException("Target ended · explicitly restart or continue");
            var manager = ActionManager.Instance();
            if (manager == null) throw new InvalidOperationException("Action manager unavailable");
            // Resolve replacements (Gemshine, upgraded Ruin, etc.) through the game's own action manager.
            var adjusted = manager->GetAdjustedActionId(r.Action);
            if (!data.GetExcelSheet<ActionRow>().TryGetRow(adjusted, out var row) || row.IsPvP) throw new InvalidOperationException("Unknown or PvP action");
            if (row.ClassJobLevel > objects.LocalPlayer.Level) throw new InvalidOperationException("Action locked by current level sync");
            var target = Resolve(r.Target) ?? throw new InvalidOperationException("Select a valid " + r.Target + " target first");
            if (r.RequestId == weave.InFlight && IsEnemy(target)) {
                if (encounterActor != 0 && encounterActor != target.GameObjectId) {
                    InterruptWeave("Spell target changed · Enter / > continue · . restart", true);
                    throw new InvalidOperationException("Explicit continuation required for a new enemy");
                }
                encounterActor = target.GameObjectId;
            }
            weave.RecordTarget(r.RequestId, r.Target, target.Name.TextValue, target.GameObjectId, adjusted);
            var castTime = ActionManager.GetAdjustedCastTime(ActionType.Action, adjusted, true);
            if (moving && castTime > 0) return new { accepted = false, retry = true, message = "Relocating · waiting for stillness" };
            if (manager->AnimationLock > 0) return new { accepted = false, retry = true, message = "Readying next step" };
            var status = manager->GetActionStatus(ActionType.Action, adjusted, target.GameObjectId);
            if (status != 0 && manager->GetActionStatus(ActionType.Action, adjusted, target.GameObjectId, checkRecastActive: false) == 0)
                return new { accepted = false, retry = true, message = "Readying next step" };
            if (status == 0 && following) { StopOwnedPath(); castHoldUntil = Environment.TickCount64 + 500; }
            var sequenceBefore = manager->LastUsedActionSequence;
            var accepted = manager->UseAction(ActionType.Action, adjusted, target.GameObjectId);
            last = $"{row.Name}: {(accepted ? "requested" : "unavailable")} (status {status})";
            var pending = accepted && r.RequestId == weave.InFlight;
            if (pending) {
                castPlayback.Begin(r.RequestId, adjusted, sequenceBefore, manager->LastUsedActionSequence, Environment.TickCount64, castTime);
                castPlayback.Poll(Environment.TickCount64, objects.LocalPlayer.IsCasting, manager->CastActionId, manager->LastUsedActionSequence, moving);
            }
            result = new { accepted, pending, action = adjusted, status, target = target.Name.TextValue, message = last };
        } else {
            if (!float.IsFinite(r.Range) || r.Range < 2 || r.Range > 25) throw new InvalidOperationException("Follow range must be 2–25 yalms");
            if (Resolve(r.Target) == null) throw new InvalidOperationException("Follow target unavailable");
            if (!pi.GetIpcSubscriber<bool>("vnavmesh.Nav.IsReady").InvokeFunc()) throw new InvalidOperationException("vnavmesh is still loading the zone mesh");
            StopFollowing("Changing follow target");
            followTarget = r.Target; followRange = r.Range; following = true;
            last = "Following " + r.Target + "; move left stick to take control.";
            result = new { requested = true, following, message = last };
        }
        lock (recentLock) { if (recent.Count > 256) recent.Clear(); recent[r.RequestId] = result; }
        return result;
    }

    private async Task Serve()
    {
        while (!shutdown.IsCancellationRequested) {
            try { var client = await listener.AcceptTcpClientAsync(shutdown.Token); _ = Handle(client); }
            catch (OperationCanceledException) { break; }
            catch (Exception ex) { if (!shutdown.IsCancellationRequested) log.Error(ex, "XivSpell listener"); }
        }
    }

    private async Task Handle(TcpClient client)
    {
        using (client) {
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(shutdown.Token);
            timeout.CancelAfter(TimeSpan.FromSeconds(5));
            var ct = timeout.Token;
            var stream = client.GetStream();
            try {
                var header = new List<byte>(); var one = new byte[1];
                while (header.Count < 16384) {
                    if (await stream.ReadAsync(one, ct) == 0) return;
                    header.Add(one[0]);
                    if (header.Count >= 4 && header.TakeLast(4).SequenceEqual(new byte[] {13,10,13,10})) break;
                }
                var lines = Encoding.ASCII.GetString(header.ToArray()).Split("\r\n");
                if (lines[0] != "POST /call HTTP/1.1") throw new InvalidOperationException("POST /call required");
                var headers = lines.Skip(1).Where(s => s.Contains(':')).ToDictionary(s => s[..s.IndexOf(':')].Trim(), s => s[(s.IndexOf(':') + 1)..].Trim(), StringComparer.OrdinalIgnoreCase);
                if (!headers.TryGetValue("Authorization", out var auth) || !CryptographicOperations.FixedTimeEquals(Encoding.UTF8.GetBytes(auth), Encoding.UTF8.GetBytes("Bearer " + config.Token))) {
                    await Reply(stream, 401, new { error = "Unauthorized" }, ct); return;
                }
                if (!headers.TryGetValue("Content-Length", out var raw) || !int.TryParse(raw, out var length) || length < 2 || length > 131072) throw new InvalidOperationException("Invalid body length");
                var body = new byte[length]; await stream.ReadExactlyAsync(body, ct);
                var request = JsonSerializer.Deserialize<Request>(body, Json) ?? throw new InvalidOperationException("Invalid request");
                var result = await framework.RunOnFrameworkThread(() => ct.IsCancellationRequested ? throw new OperationCanceledException() : Dispatch(request));
                await Reply(stream, 200, result, ct);
            } catch (Exception ex) {
                try { await Reply(stream, 400, new { error = ex.Message }, ct); } catch { /* disconnect */ }
            }
        }
    }

    private static async Task Reply(NetworkStream stream, int status, object value, CancellationToken ct)
    {
        var body = Encoding.UTF8.GetBytes(Serialize(value));
        await stream.WriteAsync(Encoding.ASCII.GetBytes($"HTTP/1.1 {status} Result\r\nContent-Type: application/json\r\nContent-Length: {body.Length}\r\nConnection: close\r\n\r\n"), ct);
        await stream.WriteAsync(body, ct);
    }

    private void Draw()
    {
        DrawSpellEditor();
        if (!visible) return;
        ImGui.SetNextWindowSize(new Vector2(410, 360), ImGuiCond.FirstUseEver);
        if (ImGui.Begin("GRIMOIRE / Lua spellcards###XivSpell", ref visible, ImGuiWindowFlags.NoNavInputs)) {
            ImGui.TextColored(new Vector4(.64f, .85f, 1, 1), "GRIMOIRE / SPELLBOOK · :e SPELL opens the editor tile");
            if (!armed) ImGui.TextUnformatted("Casting stopped · /xivspell input resumes");
            if (following && ImGui.Button("Stop following")) StopFollowing("Follow stopped");
            ImGui.TextWrapped(last);
            ImGui.Separator();
            foreach (var card in cards) {
                ImGui.PushID(card.Id);
                var appearance = SpellAppearance.Resolve(data, card);
                if (appearance is { } action) {
                    var icon = textures.GetFromGameIcon(action.Icon).GetWrapOrDefault();
                    if (icon != null) {
                        if (ImGui.ImageButton(icon.Handle, new Vector2(42, 42))) OpenSpellEditor(card.Id);
                        if (ImGui.IsItemHovered()) ImGui.SetTooltip("Edit this spell in the in-game tile · :e " + card.Id);
                        ImGui.SameLine();
                    }
                }
                ImGui.BeginGroup();
                ImGui.TextColored(new Vector4(1,.89f,.61f,1), appearance?.Name ?? card.Name);
                ImGui.Text($"{card.Phrase}  /  {card.Target}");
                ImGui.EndGroup();
                if (ImGui.IsItemHovered()) ImGui.SetTooltip(card.Source.Length > 1500 ? card.Source[..1500] : card.Source);
                ImGui.SameLine();
                if (ImGui.SmallButton("Type")) { commandText = card.Phrase; focusSpellInput = true; }
                ImGui.Separator(); ImGui.PopID();
            }
            if (cards.Length == 0) ImGui.TextWrapped("In Neovim: :Spellbook, then :SpellSync to attach your buffers here.");
        }
        ImGui.End();
    }

    private void CardInput(string id, string kind, double seconds = 0, string? requestId = null)
    {
        requestId ??= Guid.NewGuid().ToString("N");
        if (kind == "command") {
            if (commandResults.Count > 128) commandResults.Clear();
            commandResults[requestId] = new { state = "queued", command = id };
        }
        cardEvents.Enqueue(new CardEvent(++eventSequence, id, kind, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(), seconds, requestId));
        while (cardEvents.Count > 128) cardEvents.Dequeue();
        last = "Sent " + id + " to Neovim";
    }

    public void Dispose()
    {
        framework.Update -= InputUpdate;
        nativeChat.Dispose();
        disposed = true;
        armed = false; StopFollowing("Unloaded"); framework.Update -= FollowUpdate; framework.Update -= WeaveUpdate;
        void CleanupNative()
        {
            config.Weave = weave.SaveState();
            config.EditorCard = editorCard; config.EditorSource = editorSource; config.EditorOriginal = editorSavedSource; config.EditorOpen = editorOpen;
            GhosttyDalamud.PhoneModules.ModuleConfiguration.Save(pi, "Grimoire", config);
            pad?.Dispose();
            actionEffects?.Dispose();
            keyboard.Dispose();
            hudController?.Dispose();
        }
        if (framework.IsInFrameworkUpdateThread) CleanupNative();
        else framework.RunOnFrameworkThread(CleanupNative).GetAwaiter().GetResult();
        shutdown.Cancel(); listener.Stop(); ipc.Dispose();
        commands.RemoveHandler("/xivspell"); pi.UiBuilder.Draw -= Draw;
         
        shutdown.Dispose();
    }
    private sealed class Cleanup(Action dispose) : IDisposable { public void Dispose() => dispose(); }
}
