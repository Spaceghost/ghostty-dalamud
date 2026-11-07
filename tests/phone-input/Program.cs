using XivSpell;

static void Check(bool value, string message) { if (!value) throw new Exception(message); }
var key = new CombatEnterCapture();
Check(key.Poll(true, false, false, false) == (false, false), "Out-of-combat Enter is untouched");
Check(key.Poll(true, true, false, false) == (true, false), "Holding Enter across combat does not focus");
key.Poll(false, true, false, false);
Check(key.Poll(true, true, false, false) == (true, true), "Combat Enter reopens and focuses Grimoire");
Check(key.Poll(true, true, false, true) == (true, false), "Held Enter never repeatedly focuses");
key.Poll(false, true, true, true);
Check(key.Poll(true, true, true, true) == (true, false), "Enter in active Grimoire is delivered without another focus request");
key.Poll(false, false, false, true);
Check(key.Poll(true, false, false, true) == (false, false), "Unfocused game, blocked scenes, modifiers and foreign text input are untouched");

// The same ownership rules used by the native category adapter: one balanced
// operation, no restoring through a new UI generation, no repeating a restore.
var lease = new ChatVisibilityLease();
var owner = new ChatOwnerIdentity(1, 2);
int hides = 0, restores = 0;
Check(lease.TryAcquire(owner, () => { hides++; return true; }), "Acquire once");
for (int i = 0; i < 100; i++) lease.TryAcquire(owner, () => { hides++; return true; });
Check(hides == 1, "Updates cannot increment category hide counts repeatedly");
lease.Release(default, () => restores++);
Check(lease.IsHeld && restores == 0, "Temporarily missing UI retains pending restore");
lease.Release(owner, () => restores++);
lease.Release(owner, () => restores++);
Check(restores == 1, "Restore exactly once");
lease.TryAcquire(owner, () => true);
lease.Release(new ChatOwnerIdentity(3, 4), () => restores++);
Check(!lease.IsHeld && restores == 1, "An expired generation never restores another owner's UI");
lease.TryAcquire(owner, () => true);
try { lease.Release(owner, () => throw new Exception("restore failed")); } catch { }
Check(!lease.IsHeld, "Throwing restore is not repeated");
Console.WriteLine("Phone Enter routing and category ownership OK");

// Run the same weave editing cases against the embedded module sources.
var w = new SpellWeave();
(string, string)? Resolve(string s) => s == "ruin" ? ("ruin", "ruin") : s == "aegis" ? ("radiant aegis", "aegis") : null;
foreach (var c in "ruinaegis") w.Append(c, Resolve);
Check(w.Runes.Count == 2 && w.Draft == "", "full names must become stacked runes without Enter");
w.Begin("first"); w.Complete("first", true, "ok");
w.Begin("second"); Check(w.Interrupt("Escape", true) == "second", "interrupt returns active ticket");
Check(!w.InputMode && w.Paused && w.Cursor == 1, "Escape retains interrupted cursor and enters control mode");
w.Complete("second", true, "late"); Check(w.Cursor == 1, "late feedback cannot advance cursor");
w.Resume(); Check(w.Next?.CardId == "aegis", "continue starts at interrupted rune");
w.Begin("retry"); w.Complete("retry", false, "unavailable"); Check(w.Paused && w.Cursor == 1, "rejection keeps rune");
w.Repeat(); Check(w.Cursor == 0 && w.Next?.CardId == "ruin", "dot restarts whole weave");
w.EnterInput(); w.Append('x', Resolve); w.Backspace(); Check(w.Draft == "", "backspace edits draft");
w.Begin("a"); w.Complete("a", true, ""); w.Begin("b"); w.Complete("b", true, "");
Check(w.Finished, "queue finishes"); w.Repeat(); Check(w.Runes.Count == 2 && w.Cursor == 0, "completed weave can repeat");
w.Interrupt("movement"); Check(w.Paused, "movement pauses");
var full = new SpellWeave(); for (var i=0;i<32;i++) full.Add("ruin", "ruin"); Check(!full.Add("ruin", "ruin"), "queue bounded");
var edits = new SpellWeave(); edits.Add("ruin", "ruin"); edits.Add("radiant aegis", "aegis");
edits.Append('x', Resolve); edits.Backspace();
Check(edits.Draft == "" && edits.Runes.Count == 2, "erasing final character does not also erase a spell");
edits.Backspace(); Check(edits.Runes.Count == 1 && edits.Runes[0].CardId == "ruin", "empty draft deletes exactly one spell from the back");
edits.Begin("erase-active"); Check(edits.Backspace() == "erase-active", "deleting the active last spell cancels its ticket");
edits.Complete("erase-active", true, "late"); Check(edits.Runes.Count == 0 && edits.Cursor == 0, "deleted spell's late result cannot advance the line");
edits.Backspace(); Check(edits.Runes.Count == 0, "Backspace on an empty line is harmless");
edits.Add("ruin", "ruin"); edits.Begin("finished"); edits.Complete("finished", true, "");
edits.Backspace(); Check(edits.Runes.Count == 0 && edits.Cursor == 0 && edits.Finished, "completed spells can be removed without corrupting the cursor");
edits.Add("ruin", "ruin"); edits.Add("radiant aegis", "aegis"); edits.Begin("clear-active"); edits.Append('x', Resolve);
Check(edits.ClearLine() == "clear-active", "clear returns pending ticket for cancellation");
edits.Complete("clear-active", true, "late"); edits.Repeat();
Check(edits.Runes.Count == 0 && edits.Cursor == 0 && edits.InFlight == null && edits.Draft == "" && edits.Next == null, "clear removes draft, runes, repeat history and pending work");
var textHold = new BackspaceGesture(); textHold.Press(0);
Check(!textHold.Poll(299, true, true, true) && !textHold.EraseText, "text repeat waits for initial delay");
Check(!textHold.Poll(300, true, true, true) && textHold.EraseText, "held Backspace repeats text deletion");
Check(!textHold.Poll(2000, true, true, true) && textHold.EraseText, "long draft never triggers line clear");
Check(!textHold.Poll(2599, true, true), "empty draft gets a fresh clear delay");
Check(textHold.Poll(2600, true, true), "continued hold clears only after draft deletion and delay");
textHold.Release(); textHold.Press(3000);
Check(!textHold.Poll(3300, true, true, true), "draft deletion remains non-destructive");
textHold.Release(); Check(!textHold.Poll(5000, true, true), "release after deleting text preserves spells");
var hold = new BackspaceGesture(); hold.Press(1000);
Check(!hold.Poll(1599, true, true) && hold.Poll(1600, true, true), "600 ms hold clears");
Check(!hold.Poll(3000, true, true), "hold clears only once");
hold.Release(); hold.Press(4000); Check(!hold.Poll(4100, false, true), "a quick release never clears");
hold.Press(5000); Check(!hold.Poll(5600, true, false), "lost focus cancels hold");
Check(!hold.Poll(7000, true, true), "refocus with held Backspace does not start a new gesture");
Console.WriteLine("PASS automatic tokenization, stacked queue, Escape/control mode, interruption, stale feedback, continuation, repeat, editing and bounds");

if (args.Length == 2)
{
    string assembly = Path.GetFullPath(args[0]);
    var paths = Directory.GetFiles(args[1], "*.dll")
        .Concat(Directory.GetFiles(Path.GetDirectoryName(assembly)!, "*.dll"))
        .Concat(Directory.GetFiles(Path.GetDirectoryName(typeof(object).Assembly.Location)!, "*.dll"))
        .Distinct().ToArray();
    using var metadata = new System.Reflection.MetadataLoadContext(new System.Reflection.PathAssemblyResolver(paths));
    var types = metadata.LoadFromAssemblyPath(assembly).GetTypes();
    var entries = types.Where(type => type.GetInterfaces().Any(i => i.FullName is
        "Dalamud.Plugin.IDalamudPlugin" or "Dalamud.Plugin.IAsyncDalamudPlugin")).ToArray();
    Check(entries.Length == 1 && entries[0].FullName == "GhosttyDalamud.Plugin", "The built assembly must expose exactly one Dalamud plugin");
    Check(!types.Any(type => type.FullName is "XivHud.Combat.Plugin" or "XivHud.Vitals.Plugin"), "Combat and Vitals are excluded");
    foreach (string module in new[] { "XivHud.Journal.Plugin", "XivHud.Character.Plugin", "XivHud.Chat.Plugin", "XivHud.Inventory.Plugin", "XivHud.Crafting.Plugin", "XivSpell.Plugin" })
        Check(types.Any(type => type.FullName == module && !type.IsPublic), "Embedded module missing or discoverable: " + module);
    Console.WriteLine("Built assembly has one entry point, six embedded modules, and no combat HUD modules");
}
