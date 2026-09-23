// The /ask panel's game links (lua/asklinks.lua): names the game knows, found
// in its own sheets, and the few things a click on one may do. Nothing here
// moves the character, uses an action or sends a chat line to anyone: an item
// is linked into the chat input, a map opens with a flag, a journal or the
// Duty Finder opens on a row. Every action is refused in combat and runs on
// the framework thread; the core decides nothing here beyond which verb.
using System;
using System.Collections.Generic;
using System.Numerics;
using System.Text;
using System.Threading.Tasks;
using Dalamud.Game.ClientState.Conditions;
using Dalamud.Game.Text.SeStringHandling.Payloads;
using FFXIVClientStructs.FFXIV.Client.UI;
using FFXIVClientStructs.FFXIV.Client.UI.Agent;
using Lumina.Excel.Sheets;
using LuminaAction = Lumina.Excel.Sheets.Action;

namespace GhosttyDalamud;

internal static unsafe class GameLinks
{
    private enum Kind : byte { Zone, Aetheryte, Duty, Quest, Item, Action, Status, Npc }
    private static readonly string[] KindNames = ["zone", "aetheryte", "duty", "quest", "item", "action", "status", "npc"];

    private readonly record struct Hit(Kind Kind, uint Id);
    private readonly record struct Place(uint Territory, uint Map, Vector3 Pos);

    // Built once, off the framework thread, the first time an answer asks.
    private static volatile Dictionary<string, Hit>? _index;
    private static volatile Dictionary<uint, Place>? _npcAt;
    private static Task? _build;
    private static readonly object Gate = new();

    // Lower case, a leading "the " dropped: "the Praetorium" and "Praetorium" meet.
    private static string Key(string s)
    {
        s = s.Trim().ToLowerInvariant();
        return s.StartsWith("the ", StringComparison.Ordinal) ? s[4..].TrimStart() : s;
    }

    private static string Text(Lumina.Text.ReadOnly.ReadOnlySeString s)
    {
        try { return s.ExtractText(); } catch { return string.Empty; }
    }

    private static void Build()
    {
        var idx = new Dictionary<string, Hit>(StringComparer.Ordinal);
        var npcs = new HashSet<uint>();
        void Add(string name, Kind k, uint id)
        {
            if (string.IsNullOrWhiteSpace(name) || name.Length > 80) return;
            string key = Key(name);
            if (key.Length < 3) return;
            if (idx.TryAdd(key, new Hit(k, id)) && k == Kind.Npc) npcs.Add(id);
        }
        // In this order: the first sheet to name something keeps the name.
        foreach (var t in Plugin.Data.GetExcelSheet<TerritoryType>())
        {
            uint use = t.TerritoryIntendedUse.RowId; // 0 town, 1 open world (FFXIVClientStructs' TerritoryIntendedUse)
            if ((use == 0 || use == 1) && t.Map.RowId != 0 && t.PlaceName.ValueNullable is { } pn) Add(Text(pn.Name), Kind.Zone, t.RowId);
        }
        foreach (var a in Plugin.Data.GetExcelSheet<Aetheryte>())
            if (a.IsAetheryte && a.PlaceName.ValueNullable is { } pn) Add(Text(pn.Name), Kind.Aetheryte, a.RowId);
        foreach (var c in Plugin.Data.GetExcelSheet<ContentFinderCondition>()) Add(Text(c.Name), Kind.Duty, c.RowId);
        foreach (var q in Plugin.Data.GetExcelSheet<Quest>()) Add(Text(q.Name), Kind.Quest, q.RowId);
        foreach (var i in Plugin.Data.GetExcelSheet<Item>()) Add(Text(i.Name), Kind.Item, i.RowId);
        foreach (var a in Plugin.Data.GetExcelSheet<LuminaAction>())
            if (a.IsPlayerAction && !a.IsPvP) Add(Text(a.Name), Kind.Action, a.RowId);
        foreach (var s in Plugin.Data.GetExcelSheet<Status>()) Add(Text(s.Name), Kind.Status, s.RowId);
        foreach (var n in Plugin.Data.GetExcelSheet<ENpcResident>()) Add(Text(n.Singular), Kind.Npc, n.RowId);
        _index = idx;
        // where the NPCs stand, when a Level row places them
        var at = new Dictionary<uint, Place>();
        foreach (var l in Plugin.Data.GetExcelSheet<Level>())
        {
            uint obj = l.Object.RowId;
            if (npcs.Contains(obj) && !at.ContainsKey(obj) && l.Territory.RowId != 0)
                at[obj] = new Place(l.Territory.RowId, l.Map.RowId, new Vector3(l.X, l.Y, l.Z));
        }
        _npcAt = at;
    }

    private static bool Ready()
    {
        if (_index != null) return true;
        lock (Gate)
        {
            _build ??= Task.Run(() =>
            {
                try { Build(); }
                catch (Exception e) { Plugin.Log.Warning("[Ghostty] ask: the game's names could not be indexed: " + e.Message); _index = new(); }
            });
        }
        return false;
    }

    // No tabs or line ends inside a field; a line end in a detail is written \n.
    private static string Field(string s) => s.Replace('\t', ' ').Replace("\r", "").Replace("\n", "\\n");

    private static string Cut(string s, int max) => s.Length <= max ? s : s[..(max - 1)].TrimEnd() + "…";

    private static void Describe(Hit h, out uint icon, out string name, out uint territory, out uint map, out string detail)
    {
        icon = 0; name = string.Empty; territory = 0; map = 0; detail = string.Empty;
        switch (h.Kind)
        {
            case Kind.Item:
                if (Plugin.Data.GetExcelSheet<Item>().GetRowOrDefault(h.Id) is { } it)
                {
                    icon = it.Icon;
                    name = Text(it.Name);
                    string cat = it.ItemUICategory.ValueNullable is { } c ? Text(c.Name) : string.Empty;
                    detail = (cat.Length > 0 ? cat + " · " : "") + "iLvl " + it.LevelItem.RowId;
                    string desc = Text(it.Description).Trim();
                    if (desc.Length > 0) detail += "\n" + Cut(desc, 240);
                }
                break;
            case Kind.Zone:
                if (Plugin.Data.GetExcelSheet<TerritoryType>().GetRowOrDefault(h.Id) is { } t)
                {
                    territory = t.RowId;
                    map = t.Map.RowId;
                    name = t.PlaceName.ValueNullable is { } pn ? Text(pn.Name) : string.Empty;
                    detail = t.PlaceNameRegion.ValueNullable is { } r ? Text(r.Name) : string.Empty;
                }
                break;
            case Kind.Aetheryte:
                if (Plugin.Data.GetExcelSheet<Aetheryte>().GetRowOrDefault(h.Id) is { } a)
                {
                    territory = a.Territory.RowId;
                    map = a.Map.RowId;
                    name = a.PlaceName.ValueNullable is { } pn ? Text(pn.Name) : string.Empty;
                    detail = a.Territory.ValueNullable is { } tt && tt.PlaceName.ValueNullable is { } zn ? Text(zn.Name) : string.Empty;
                }
                break;
            case Kind.Duty:
                if (Plugin.Data.GetExcelSheet<ContentFinderCondition>().GetRowOrDefault(h.Id) is { } d)
                {
                    name = Text(d.Name);
                    string type = d.ContentType.ValueNullable is { } ct ? Text(ct.Name) : string.Empty;
                    if (d.ContentType.ValueNullable is { } cti) icon = cti.Icon;
                    detail = (type.Length > 0 ? type + " · " : "") + "Lv " + d.ClassJobLevelRequired
                        + (d.ItemLevelRequired > 0 ? " · iLvl " + d.ItemLevelRequired : "");
                }
                break;
            case Kind.Quest:
                if (Plugin.Data.GetExcelSheet<Quest>().GetRowOrDefault(h.Id) is { } q)
                {
                    name = Text(q.Name);
                    if (q.JournalGenre.ValueNullable is { } g)
                    {
                        icon = (uint)Math.Max(g.Icon, 0);
                        detail = Text(g.Name);
                    }
                    ushort lv = q.ClassJobLevel.Count > 0 ? q.ClassJobLevel[0] : (ushort)0;
                    if (lv > 0) detail = (detail.Length > 0 ? detail + " · " : "") + "Lv " + lv;
                    if (q.PlaceName.ValueNullable is { } qp && Text(qp.Name) is { Length: > 0 } wn) detail += "\n" + wn;
                }
                break;
            case Kind.Action:
                if (Plugin.Data.GetExcelSheet<LuminaAction>().GetRowOrDefault(h.Id) is { } ac)
                {
                    icon = ac.Icon;
                    name = Text(ac.Name);
                    string job = ac.ClassJob.ValueNullable is { } j ? Text(j.Abbreviation) : string.Empty;
                    detail = (job.Length > 0 ? job + " · " : "") + (ac.ClassJobLevel > 0 ? "Lv " + ac.ClassJobLevel : "");
                }
                break;
            case Kind.Status:
                if (Plugin.Data.GetExcelSheet<Status>().GetRowOrDefault(h.Id) is { } s)
                {
                    icon = s.Icon;
                    name = Text(s.Name);
                    detail = Cut(Text(s.Description).Trim(), 240);
                }
                break;
            case Kind.Npc:
                if (Plugin.Data.GetExcelSheet<ENpcResident>().GetRowOrDefault(h.Id) is { } n)
                {
                    name = Text(n.Singular);
                    if (_npcAt is { } at && at.TryGetValue(h.Id, out var p))
                    {
                        territory = p.Territory;
                        map = p.Map;
                        if (Plugin.Data.GetExcelSheet<TerritoryType>().GetRowOrDefault(p.Territory) is { } nt && nt.PlaceName.ValueNullable is { } np)
                            detail = Text(np.Name);
                    }
                }
                break;
        }
    }

    // "pending" while the names are still being indexed (ask again), else "ok"
    // and a line per name known: query, kind, id, icon, name, territory, map, detail.
    public static string Lookup(string request)
    {
        if (!Ready()) return "pending\n";
        var idx = _index!;
        var sb = new StringBuilder("ok\n");
        int n = 0;
        foreach (string raw in request.Split('\n'))
        {
            string q = raw.Trim();
            if (q.Length == 0 || q.Length > 80 || !idx.TryGetValue(Key(q), out var h)) continue;
            if (++n > 400) break;
            Describe(h, out uint icon, out string name, out uint territory, out uint map, out string detail);
            sb.Append(Field(q)).Append('\t').Append(KindNames[(int)h.Kind]).Append('\t').Append(h.Id).Append('\t')
              .Append(icon).Append('\t').Append(Field(name)).Append('\t').Append(territory).Append('\t').Append(map)
              .Append('\t').Append(Field(detail)).Append('\n');
        }
        return sb.ToString();
    }

    // 1 done (or queued on the framework thread), 0 not possible, 2 in combat, 3 not logged in.
    //   flag        "territory\tmap\tx\ty": map coordinates; territory 0 is where you are
    //   open        "kind\tid": item (linked in the chat input), zone (its map),
    //               aetheryte and npc (a flag where they are), quest (journal), duty (Duty Finder)
    //   chat_input  text put in the chat input box, not sent
    //   chat_run    a slash command run as if typed; chat channels refused
    public static int Action(string verb, string arg)
    {
        if (!Plugin.Client.IsLoggedIn) return 3;
        if (Plugin.Condition[ConditionFlag.InCombat]) return 2;
        string[] f = arg.Split('\t');
        switch (verb)
        {
            case "flag":
            {
                if (f.Length < 4 || !uint.TryParse(f[0], out uint terr) || !uint.TryParse(f[1], out uint map)
                    || !float.TryParse(f[2], System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out float x)
                    || !float.TryParse(f[3], System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out float y))
                    return 0;
                if (terr == 0 || map == 0) { terr = Plugin.Client.TerritoryType; map = Plugin.Client.MapId; }
                if (terr == 0 || map == 0) return 0;
                var link = new MapLinkPayload(terr, map, x, y, 0.05f);
                return Queue(() => Plugin.GameGui.OpenMapWithMapLink(link));
            }
            case "open":
            {
                if (f.Length < 2 || !uint.TryParse(f[1], out uint id)) return 0;
                return f[0] switch
                {
                    "item" => Queue(() => { var a = AgentChatLog.Instance(); if (a != null) a->LinkItem(id); }),
                    "zone" => OpenZone(id),
                    "aetheryte" => FlagAetheryte(id),
                    "npc" => FlagNpc(id),
                    "quest" => Queue(() => { var a = AgentQuestJournal.Instance(); if (a != null) a->OpenForQuest(id & 0xFFFF, 1); }),
                    "duty" => Queue(() => { var a = AgentContentsFinder.Instance(); if (a != null) a->OpenRegularDuty(id); }),
                    _ => 0,
                };
            }
            case "chat_input":
                if (arg.Length == 0 || arg.Length > 500 || arg.Contains('\n')) return 0;
                return Queue(() =>
                {
                    var addon = (AddonChatLog*)Plugin.GameGui.GetAddonByName("ChatLog", 1).Address;
                    if (addon != null && addon->TextInput != null) addon->TextInput->SetText(arg);
                });
            case "chat_run":
                if (!arg.StartsWith('/') || arg.Contains('\n') || SaysSomething(arg)) return 0;
                return HostApi.QueueChat(arg) ? 1 : 0;
        }
        return 0;
    }

    private static int Queue(System.Action act)
    {
        Plugin.GameFramework.RunOnFrameworkThread(() =>
        {
            try
            {
                if (Plugin.Condition[ConditionFlag.InCombat]) return; // it started while this waited
                act();
            }
            catch (Exception e) { Plugin.Log.Warning("[Ghostty] ask: " + e.Message); }
        });
        return 1;
    }

    private static int OpenZone(uint territory)
    {
        if (Plugin.Data.GetExcelSheet<TerritoryType>().GetRowOrDefault(territory) is not { } t || t.Map.RowId == 0) return 0;
        uint map = t.Map.RowId;
        return Queue(() => { var a = AgentMap.Instance(); if (a != null) a->OpenMapByMapId(map, territory); });
    }

    private static int FlagAetheryte(uint id)
    {
        if (Plugin.Data.GetExcelSheet<Aetheryte>().GetRowOrDefault(id) is not { } a) return 0;
        uint terr = a.Territory.RowId, map = a.Map.RowId;
        if (terr == 0 || map == 0) return 0;
        foreach (var lr in a.Level)
        {
            if (lr.RowId != 0 && lr.ValueNullable is { } l)
                return Queue(() => Plugin.GameGui.OpenMapWithMapLink(terr, map, new Vector3(l.X, l.Y, l.Z)));
        }
        return Queue(() => { var m = AgentMap.Instance(); if (m != null) m->OpenMapByMapId(map, terr); });
    }

    private static int FlagNpc(uint id)
    {
        if (_npcAt is not { } at || !at.TryGetValue(id, out var p) || p.Map == 0) return 0;
        return Queue(() => Plugin.GameGui.OpenMapWithMapLink(p.Territory, p.Map, p.Pos));
    }

    // Chat channels and emotes others see; lua/asklinks.lua refuses them first.
    private static readonly HashSet<string> Channels = new(StringComparer.OrdinalIgnoreCase)
    {
        "s", "say", "sh", "shout", "y", "yell", "t", "tell", "r", "reply", "p", "party", "fc", "freecompany",
        "a", "alliance", "n", "novice", "beginner", "em", "emote", "pvpteam", "cwlinkshell", "linkshell", "l",
        "cwl", "ls", "fellowship", "fw",
    };

    private static bool SaysSomething(string cmd)
    {
        int i = 1;
        while (i < cmd.Length && char.IsAsciiLetter(cmd[i])) i++;
        return Channels.Contains(cmd[1..i]);
    }

    // A game icon as an ImTextureID, 0 until Dalamud has loaded it; asked again each frame it is drawn.
    public static nint Icon(uint id, uint* w, uint* h)
    {
        if (id == 0) return 0;
        try
        {
            Dalamud.Interface.Textures.GameIconLookup look = id;
            if (!Plugin.Textures.GetFromGameIcon(look).TryGetWrap(out var wrap, out _) || wrap == null) return 0;
            if (w != null) *w = (uint)wrap.Width;
            if (h != null) *h = (uint)wrap.Height;
            return (nint)wrap.Handle.Handle;
        }
        catch { return 0; }
    }
}
