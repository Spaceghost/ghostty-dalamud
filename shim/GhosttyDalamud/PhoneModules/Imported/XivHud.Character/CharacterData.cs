using Dalamud.Plugin.Services;
using FFXIVClientStructs.FFXIV.Client.Game;
using FFXIVClientStructs.FFXIV.Client.Game.UI;
using FFXIVClientStructs.FFXIV.Client.UI.Info;
using FFXIVClientStructs.FFXIV.Client.UI.Misc;
using Lumina.Excel;
using Lumina.Excel.Sheets;
using CsCharacter = FFXIVClientStructs.FFXIV.Client.Game.Character.Character;
using PlayerAttribute = Dalamud.Game.Player.PlayerAttribute;
using Sex = Dalamud.Game.Player.Sex;

namespace XivHud.Character;

public sealed record CharacterSnapshot(
    CharacterIdentity Identity, CharacterJob Job, CharacterPools Pools, int AverageItemLevel,
    IReadOnlyList<GearPiece> Gear, IReadOnlyList<StatSection> Attributes,
    IReadOnlyList<JobEntry> Jobs, IReadOnlyList<GearSetEntry> GearSets);

public sealed record CharacterIdentity(
    string Name, string Title, bool TitleIsPrefix, string World, string HomeWorld,
    string Race, string Tribe, string Gender, string CityState, string Nameday,
    string Guardian, string GrandCompany, string GrandCompanyRank, string FreeCompany);

public sealed record CharacterJob(uint Id, string Name, string Abbreviation, int Level, bool Synced, int SyncedLevel,
    byte Role, uint Category, uint PrimaryStat, uint IconId, uint SoulCrystalIcon);

/// <summary>Pools come from the local player object, which can be absent while the profile is loaded.</summary>
public readonly record struct CharacterPools(bool Available, uint Hp, uint MaxHp, string SecondaryLabel, uint Secondary, uint MaxSecondary);

public sealed record GearPiece(
    int Slot, string SlotName, uint ItemId, string Name, string Category, uint Icon, bool HighQuality,
    int ItemLevel, int EquipLevel, float Condition, float Spiritbond, bool Collectable, int Collectability,
    IReadOnlyList<MateriaEntry> Materia, int MateriaSlots, IReadOnlyList<StatValue> Stats, float Delay,
    string Glamour, IReadOnlyList<string> Dyes, bool BlocksOffHand, string Note = "")
{
    internal bool IsEmpty => ItemId == 0;
}

public readonly record struct MateriaEntry(string Name, string Stat, int Value);
public readonly record struct StatValue(uint Id, string Name, int Value, bool Emphasis = false);
public sealed record StatSection(string Name, IReadOnlyList<StatValue> Stats);

public sealed record JobEntry(uint Id, string Name, string Abbreviation, JobSection Section, int Priority,
    uint IconId, uint SoulCrystalIcon, int Level, long Experience, long ExperienceToNext, bool Max, bool Current)
{
    internal bool Locked => Level <= 0;
}

public sealed record GearSetEntry(int Id, string Name, uint JobId, string JobAbbreviation, uint JobIcon,
    uint SoulCrystalIcon, int ItemLevel, bool Current)
{
    internal int Number => Id + 1;
}

/// <summary>Framework-thread snapshots of the local character; no native pointers escape a read.</summary>
public sealed unsafe class CharacterData(IDataManager data, IPlayerState player, IObjectTable objects, IUnlockState unlocks)
{
    private readonly Dictionary<uint, ItemInfo> items = [];
    private readonly Dictionary<uint, string> statNames = [];
    private readonly Dictionary<(uint Row, byte Grade), MateriaEntry?> materia = [];
    private readonly Dictionary<uint, string> stains = [];
    private JobInfo[]? jobs;
    private GearPiece[]? lastGear;
    private int lastAverage;
    private long[]? growth;

    private readonly record struct ItemInfo(string Name, string Category, uint Icon, int ItemLevel, int EquipLevel,
        bool BlocksOffHand, int MateriaSlots, (uint, int)[] BaseValues, (uint, int)[] Special, uint SpecialKind, float Delay,
        uint HiddenDamage);
    private sealed record JobInfo(uint Id, string Name, string Abbreviation, byte Role, uint Category, byte JobIndex,
        uint Parent, bool Limited, byte Priority, uint PrimaryStat, uint SoulCrystalIcon, uint UnlockQuest, ClassJob Row);

    /// <remarks>Call on the framework thread while logged in, normally every 400–500 ms.
    /// Returns null until the game's player profile is loaded.</remarks>
    public CharacterSnapshot? Read()
    {
        if (!player.IsLoaded) return null;
        var table = Jobs();
        var current = player.ClassJob.RowId;
        var job = Array.Find(table, j => j.Id == current);
        var gear = Gear(out var computedAverage);
        var ui = UIState.Instance();
        var nativeAverage = ui == null ? 0 : ui->CurrentItemLevel;
        return new CharacterSnapshot(
            Identity(),
            new CharacterJob(current, job?.Name ?? "Adventurer", job?.Abbreviation ?? "ADV", player.Level,
                player.IsLevelSynced, player.EffectiveLevel, job?.Role ?? 0, job?.Category ?? 0,
                job?.PrimaryStat ?? 0, CharacterMath.JobIconBase + current, job?.SoulCrystalIcon ?? 0),
            Pools(job?.Category ?? 0),
            // The game's own figure (as shown in the Character window); computed only when it reads 0.
            nativeAverage != 0 ? nativeAverage : computedAverage,
            gear, Attributes(job), JobList(table, current), GearSets(table));
    }

    /// <summary>Framework thread only. 0 is accepted by the game; -1 is a refusal.</summary>
    public static int EquipGearset(int id)
    {
        var module = RaptureGearsetModule.Instance();
        if (module == null || id is < 0 or >= 100 || !module->IsValidGearset(id)) return -1;
        return module->EquipGearset(id);
    }

    private CharacterIdentity Identity()
    {
        var female = player.Sex == Sex.Female;
        var local = objects.LocalPlayer;
        var (title, prefix) = Title(local?.Address ?? 0, female);
        var gc = player.GrandCompany;
        var rank = gc.RowId is >= 1 and <= 3 && gc.IsValid ? player.GetGrandCompanyRank(gc.Value) : (byte)0;
        return new CharacterIdentity(
            player.CharacterName,
            title, prefix,
            Text(player.CurrentWorld.ValueNullable?.Name),
            Text(player.HomeWorld.ValueNullable?.Name),
            Text(female ? player.Race.ValueNullable?.Feminine : player.Race.ValueNullable?.Masculine),
            Text(female ? player.Tribe.ValueNullable?.Feminine : player.Tribe.ValueNullable?.Masculine),
            female ? "Female" : "Male",
            Text(player.StartTown.ValueNullable?.Name),
            CharacterMath.Nameday(player.BirthMonth, player.BirthDay),
            Text(player.GuardianDeity.ValueNullable?.Name),
            gc.RowId == 0 ? "" : Text(gc.ValueNullable?.Name),
            rank == 0 ? "" : GrandCompanyRank(gc.RowId, rank, female),
            FreeCompany(local?.CompanyTag.TextValue));
    }

    private (string Text, bool Prefix) Title(nint address, bool female)
    {
        if (address == 0) return ("", false);
        var id = ((CsCharacter*)address)->CharacterData.TitleId;
        if (id == 0 || data.GetExcelSheet<Title>().GetRowOrDefault(id) is not { } row) return ("", false);
        return (Text(female ? row.Feminine : row.Masculine), row.IsPrefix);
    }

    private string GrandCompanyRank(uint company, byte rank, bool female)
    {
        // GC 1 Maelstrom (Limsa), 2 Twin Adder (Gridania), 3 Immortal Flames (Ul'dah); row id = rank.
        return (company, female) switch
        {
            (1, false) => Text(data.GetExcelSheet<GCRankLimsaMaleText>().GetRowOrDefault(rank)?.Singular),
            (1, true) => Text(data.GetExcelSheet<GCRankLimsaFemaleText>().GetRowOrDefault(rank)?.Singular),
            (2, false) => Text(data.GetExcelSheet<GCRankGridaniaMaleText>().GetRowOrDefault(rank)?.Singular),
            (2, true) => Text(data.GetExcelSheet<GCRankGridaniaFemaleText>().GetRowOrDefault(rank)?.Singular),
            (3, false) => Text(data.GetExcelSheet<GCRankUldahMaleText>().GetRowOrDefault(rank)?.Singular),
            (3, true) => Text(data.GetExcelSheet<GCRankUldahFemaleText>().GetRowOrDefault(rank)?.Singular),
            _ => "",
        };
    }

    private static string FreeCompany(string? tag)
    {
        try
        {
            var proxy = InfoProxyFreeCompany.Instance();
            if (proxy != null && proxy->Id != 0)
            {
                var name = proxy->NameString;
                if (!string.IsNullOrWhiteSpace(name)) return name;
            }
        }
        catch
        {
            // The info proxy lookup is signature-resolved. The company tag remains a safe fallback.
        }
        return string.IsNullOrWhiteSpace(tag) ? "" : $"«{tag}»";
    }

    private CharacterPools Pools(uint category)
    {
        var label = CharacterMath.PoolLabel(category);
        if (objects.LocalPlayer is not { } local) return new(false, 0, 0, label, 0, 0);
        var (value, max) = label switch
        {
            "CP" => (local.CurrentCp, local.MaxCp),
            "GP" => (local.CurrentGp, local.MaxGp),
            _ => (local.CurrentMp, local.MaxMp),
        };
        return new(true, local.CurrentHp, local.MaxHp, label, value, max);
    }

    private IReadOnlyList<StatSection> Attributes(JobInfo? job)
    {
        var result = new List<StatSection>();
        foreach (var (section, ids) in CharacterMath.Sections(CharacterMath.LayoutFor(job?.Category ?? 0)))
        {
            var stats = new StatValue[ids.Length];
            for (var i = 0; i < ids.Length; i++)
                stats[i] = new StatValue(ids[i], StatName(ids[i]), player.GetAttribute((PlayerAttribute)ids[i]),
                    CharacterMath.Emphasized(ids[i], job?.PrimaryStat ?? 0, job?.Role ?? 0));
            result.Add(new StatSection(section, stats));
        }
        return result;
    }

    private IReadOnlyList<GearPiece> Gear(out int computedAverage)
    {
        computedAverage = lastAverage;
        var pieces = new GearPiece?[CharacterMath.SlotCount];
        var manager = InventoryManager.Instance();
        var container = manager == null ? null : manager->GetInventoryContainer(InventoryType.EquippedItems);
        // During transitions the container can be unloaded: keep the last real reading
        // rather than presenting every slot as empty.
        if ((container == null || !container->IsLoaded) && lastGear is not null) return lastGear;
        if (container != null && container->IsLoaded)
        {
            // Container index == GearsetItemIndex (0 main hand … 13 soul crystal; 5 waist is always empty).
            var size = Math.Min(container->Size, CharacterMath.SlotCount);
            for (var i = 0; i < size; i++)
            {
                if (i == CharacterMath.Waist) continue;
                var slot = container->GetInventorySlot(i);
                if (slot == null || slot->IsEmpty()) continue;
                pieces[i] = Piece(i, slot);
            }
        }
        computedAverage = CharacterMath.AverageItemLevel(pieces.Where(p => p is not null)
            .Select(p => (p!.Slot, p.ItemLevel, p.BlocksOffHand)));
        var twoHanded = pieces[CharacterMath.MainHand]?.BlocksOffHand == true;
        var gear = CharacterMath.EquipmentOrder.Select(i => pieces[i] ?? Empty(i,
            i == CharacterMath.OffHand && twoHanded ? "Held by your two-handed weapon" : "")).ToArray();
        if (container != null && container->IsLoaded) { lastGear = gear; lastAverage = computedAverage; }
        return gear;
    }

    private static GearPiece Empty(int slot, string note) => new(slot, CharacterMath.SlotNames[slot], 0, "", "", 0, false,
        0, 0, 0, 0, false, 0, [], 0, [], 0, "", [], false, note);

    private GearPiece? Piece(int index, InventoryItem* slot)
    {
        // Sheet rows are keyed by the base id; GetItemId() adds the HQ/collectable offsets.
        var id = slot->GetBaseItemId();
        if (id == 0 || Item(id) is not { } info) return null;
        var hq = slot->IsHighQuality();
        var collectable = slot->IsCollectable();
        var bond = slot->GetSpiritbondOrCollectability();
        var stats = CharacterMath.ItemStats(info.BaseValues, info.Special, info.SpecialKind, hq)
            .Where(p => p.BaseParam != info.HiddenDamage).Select(p => new StatValue(p.BaseParam, StatName(p.BaseParam), p.Value)).ToArray();
        var melds = new List<MateriaEntry>(5);
        for (byte m = 0; m < 5; m++)
        {
            var row = slot->GetMateriaId(m);
            // A meld is never dropped: an unusable sheet row keeps its socket as "Materia".
            if (row != 0) melds.Add(Materia(row, slot->GetMateriaGrade(m)) ?? new MateriaEntry("Materia", "", 0));
        }
        var dyes = new List<string>(2);
        for (var s = 0; s < 2; s++)
        {
            var stain = slot->GetStain(s);
            if (stain != 0 && StainName(stain) is { Length: > 0 } name) dyes.Add(name);
        }
        var glamour = slot->GetGlamourId();
        return new GearPiece(index, CharacterMath.SlotNames[index], id, info.Name, info.Category, info.Icon, hq,
            info.ItemLevel, info.EquipLevel,
            // Condition 30000 = 100%. The shared spiritbond field is hundredths of a percent unless collectable.
            slot->Condition / 300f, collectable ? 0 : bond / 100f, collectable, collectable ? bond : 0,
            melds, info.MateriaSlots, stats, info.Delay,
            glamour != 0 && glamour != id && Item(glamour) is { } look ? look.Name : "",
            dyes, info.BlocksOffHand);
    }

    private ItemInfo? Item(uint id)
    {
        if (items.TryGetValue(id, out var found)) return found;
        if (data.GetExcelSheet<Item>().GetRowOrDefault(id) is not { } row) return null;
        // Dedicated weapon/armour columns map to Physical/Magic Damage, Block Rate/Strength
        // and Defense/Magic Defense; HQ special entries add to the same base params.
        var values = new List<(uint, int)>
        {
            (12, row.DamagePhys), (13, row.DamageMag), (17, row.BlockRate), (18, row.Block),
            (21, row.DefensePhys), (24, row.DefenseMag),
        };
        for (var i = 0; i < row.BaseParam.Count && i < row.BaseParamValue.Count; i++)
            values.Add((row.BaseParam[i].RowId, row.BaseParamValue[i]));
        var special = new List<(uint, int)>();
        for (var i = 0; i < row.BaseParamSpecial.Count && i < row.BaseParamValueSpecial.Count; i++)
            special.Add((row.BaseParamSpecial[i].RowId, row.BaseParamValueSpecial[i]));
        var name = Text(row.Name);
        // Weapons carry both damage columns (casters' are usually equal); show the one the
        // weapon's class uses: Magic Damage for Disciples of Magic, Physical Damage otherwise.
        var weapon = row.EquipSlotCategory.RowId is 1 or 13;
        var hidden = !weapon ? 0u : row.ClassJobUse.ValueNullable?.ClassJobCategory.RowId == 31 ? 12u : 13u;
        var info = new ItemInfo(name.Length == 0 ? $"Item {id}" : name, Text(row.ItemUICategory.ValueNullable?.Name),
            row.Icon, (int)row.LevelItem.RowId, row.LevelEquip,
            row.EquipSlotCategory.ValueNullable is { OffHand: -1 }, row.MateriaSlotCount,
            values.ToArray(), special.ToArray(), row.ItemSpecialBonus.RowId,
            weapon && row.Delayms > 0 ? row.Delayms / 1000f : 0, hidden);
        items[id] = info;
        return info;
    }

    private MateriaEntry? Materia(ushort row, byte grade)
    {
        if (materia.TryGetValue((row, grade), out var found)) return found;
        MateriaEntry? entry = null;
        // Most Materia rows are unused placeholders: require a stat, an item and a value at this grade.
        if (data.GetExcelSheet<Materia>().GetRowOrDefault(row) is { } sheet && sheet.BaseParam.RowId != 0 &&
            grade < sheet.Item.Count && grade < sheet.Value.Count && sheet.Item[grade].RowId != 0 && sheet.Value[grade] != 0)
        {
            var item = sheet.Item[grade].ValueNullable;
            entry = new MateriaEntry(item is { } i ? Text(i.Name) : "Materia", StatName(sheet.BaseParam.RowId), sheet.Value[grade]);
        }
        materia[(row, grade)] = entry;
        return entry;
    }

    private string StainName(byte id)
    {
        if (stains.TryGetValue(id, out var found)) return found;
        var name = Text(data.GetExcelSheet<Stain>().GetRowOrDefault(id)?.Name);
        stains[id] = name;
        return name;
    }

    private string StatName(uint id)
    {
        if (statNames.TryGetValue(id, out var found)) return found;
        var name = Text(data.GetExcelSheet<BaseParam>().GetRowOrDefault(id)?.Name);
        if (name.Length == 0) name = $"Attribute {id}";
        statNames[id] = name;
        return name;
    }

    private JobInfo[] Jobs()
    {
        if (jobs is not null) return jobs;
        var list = new List<JobInfo>();
        foreach (var row in data.GetExcelSheet<ClassJob>())
        {
            var abbreviation = Text(row.Abbreviation);
            // Rows 44/45 are blank but carry ExpArrayIndex 0: the abbreviation check is load-bearing.
            if (row.RowId == 0 || row.ExpArrayIndex < 0 || abbreviation.Length == 0) continue;
            list.Add(new JobInfo(row.RowId, CharacterMath.TitleCase(Text(row.Name)), abbreviation, row.Role,
                row.ClassJobCategory.RowId, row.JobIndex, row.ClassJobParent.RowId, row.IsLimitedJob, row.UIPriority,
                row.PrimaryStat, row.ItemSoulCrystal.ValueNullable?.Icon ?? 0u, row.UnlockQuest.RowId, row));
        }
        return jobs = list.ToArray();
    }

    private long ExpToNext(int level)
    {
        if (growth is null)
        {
            var sheet = data.GetExcelSheet<ParamGrow>();
            growth = new long[sheet.Count + 2];
            foreach (var row in sheet)
                if (row.RowId < growth.Length) growth[row.RowId] = row.ExpToNext;
        }
        return level >= 0 && level < growth.Length ? growth[level] : 0;
    }

    private IReadOnlyList<JobEntry> JobList(JobInfo[] table, uint current)
    {
        var result = new List<JobEntry>(table.Length);
        var shownClasses = new HashSet<uint>();
        // Exactly one row is current: the displayed row itself, else the first job folded from it.
        var exact = table.Any(j => j.Id == current && CharacterMath.SectionFor(j.Role, j.Category, j.JobIndex, j.Parent, j.Id, j.Limited, j.Abbreviation) is not null
            && !CharacterMath.ShowAsBaseClass(j.Id, j.Parent, JobUnlocked(j)));
        var currentAssigned = false;
        foreach (var job in table)
        {
            if (CharacterMath.SectionFor(job.Role, job.Category, job.JobIndex, job.Parent, job.Id, job.Limited, job.Abbreviation) is not { } section)
                continue;
            var shown = job;
            if (CharacterMath.ShowAsBaseClass(job.Id, job.Parent, JobUnlocked(job)))
            {
                // Arcanist precedes both Summoner and Scholar; it appears once, among the casters.
                if (!shownClasses.Add(job.Parent) || Array.Find(table, j => j.Id == job.Parent) is not { } parent ||
                    CharacterMath.RoleSection(parent.Role, parent.Category) is not { } parentSection) continue;
                shown = parent; section = parentSection;
            }
            // Levels and experience are indexed by ExpArrayIndex, shared by a class and its jobs.
            int level = player.GetClassJobLevel(job.Row);
            long exp = player.GetClassJobExperience(job.Row);
            var max = CharacterMath.IsMaxLevel(job.Id, level, ExpToNext(level + 1));
            var isCurrent = !currentAssigned && (exact ? shown.Id == current : shown.Id == current || job.Parent == current);
            currentAssigned |= isCurrent;
            result.Add(new JobEntry(shown.Id, shown.Name, shown.Abbreviation, section, shown.Priority,
                CharacterMath.JobIconBase + shown.Id, shown.SoulCrystalIcon, level, max ? 0 : exp,
                max || level <= 0 ? 0 : ExpToNext(level), max, isCurrent));
        }
        return result.OrderBy(j => j.Section).ThenBy(j => j.Priority).ThenBy(j => j.Id).ToArray();
    }

    private bool JobUnlocked(JobInfo job)
    {
        if (job.UnlockQuest == 0) return true;
        try
        {
            return data.GetExcelSheet<Quest>().GetRowOrDefault(job.UnlockQuest) is { } quest && unlocks.IsQuestCompleted(quest);
        }
        catch
        {
            // Unknown unlock state: show the job by name; its shared level is still correct.
            return true;
        }
    }

    private IReadOnlyList<GearSetEntry> GearSets(JobInfo[] table)
    {
        var module = RaptureGearsetModule.Instance();
        if (module == null) return [];
        var result = new List<GearSetEntry>();
        try
        {
            var current = module->CurrentGearsetIndex;
            var entries = module->Entries;
            for (var i = 0; i < entries.Length; i++)
            {
                if (!module->IsValidGearset(i)) continue;
                ref var entry = ref entries[i];
                if (!entry.Flags.HasFlag(RaptureGearsetModule.GearsetFlag.Exists)) continue;
                var jobId = entry.ClassJob;
                var job = Array.Find(table, j => j.Id == jobId);
                var name = entry.NameString;
                result.Add(new GearSetEntry(i, string.IsNullOrWhiteSpace(name) ? $"Gear Set {i + 1}" : name.Trim(),
                    entry.ClassJob, job?.Abbreviation ?? "", CharacterMath.JobIconBase + entry.ClassJob,
                    job?.SoulCrystalIcon ?? 0, entry.ItemLevel, i == current));
            }
        }
        catch
        {
            // Gear set validity is signature-resolved; the rest of the record stays available.
            return result;
        }
        return result;
    }

    private static string Text(Lumina.Text.ReadOnly.ReadOnlySeString? text) => text?.ExtractText().Trim() ?? "";
}
