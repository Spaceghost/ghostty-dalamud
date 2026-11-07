namespace XivHud.Character;

/// <summary>Pure rules for the character sheet. Everything here is unit tested and reads no game memory.</summary>
internal static class CharacterMath
{
    internal const int MainHand = 0, OffHand = 1, Waist = 5, SoulCrystal = 13, SlotCount = 14;
    internal const int MainCommandCharacter = 2, MainCommandArmoury = 25;
    internal const uint JobIconBase = 62100;
    internal const uint BlueMage = 36;
    internal const int BlueMageCap = 80;

    internal static readonly string[] SlotNames =
    [
        "Main Hand", "Off Hand", "Head", "Body", "Hands", "Waist", "Legs", "Feet",
        "Earrings", "Necklace", "Bracelets", "Ring", "Ring", "Soul Crystal",
    ];

    /// <summary>Equipped-container slots in two groups: arms and armour (weapons first), then
    /// accessories and the soul crystal. The waist slot no longer exists in play and is never shown.</summary>
    internal static readonly int[] EquipmentOrder = [0, 1, 2, 3, 4, 6, 7, 8, 9, 10, 11, 12, 13];
    internal const int EquipmentHalf = 7;

    /// <summary>Fallback for the game's own average when it reads 0. Twelve slots, waist and soul
    /// crystal excluded (crystals are 30, 136 or 1), a two-handed main hand counted twice.</summary>
    internal static int AverageItemLevel(IEnumerable<(int Slot, int ItemLevel, bool BlocksOffHand)> pieces)
    {
        var sum = 0;
        foreach (var (slot, level, twoHanded) in pieces)
        {
            if (slot is Waist or SoulCrystal or < 0 or >= SlotCount) continue;
            sum += level;
            if (slot == MainHand && twoHanded) sum += level;
        }
        return sum / 12;
    }

    /// <summary>Item stats in base-param order. The special columns are an HQ bonus only for
    /// ItemSpecialBonus 1 on an HQ item; other bonus kinds reuse the same columns.</summary>
    internal static IReadOnlyList<(uint BaseParam, int Value)> ItemStats(
        IEnumerable<(uint BaseParam, int Value)> baseValues,
        IEnumerable<(uint BaseParam, int Value)> special, uint specialBonusKind, bool highQuality)
    {
        var values = new Dictionary<uint, int>();
        var order = new List<uint>();
        void Add(uint id, int value)
        {
            if (id == 0 || value == 0) return;
            if (!values.ContainsKey(id)) { values[id] = 0; order.Add(id); }
            values[id] += value;
        }
        foreach (var (id, value) in baseValues) Add(id, value);
        if (highQuality && specialBonusKind == 1)
            foreach (var (id, value) in special)
                if (values.ContainsKey(id)) values[id] += value; else Add(id, value);
        return order.Select(id => (id, values[id])).Where(p => p.Item2 != 0).ToArray();
    }

    /// <summary>Base params the item sheet stores as dedicated weapon/armour columns rather than
    /// bonuses. They head the item page as large figures.</summary>
    internal static bool IsPrimaryItemStat(uint baseParam) => baseParam is 12 or 13 or 17 or 18 or 21 or 24;

    internal static string Nameday(int month, int day)
    {
        if (month is < 1 or > 12 || day is < 1 or > 32) return "";
        var moon = (month + 1) / 2;
        return $"{Ordinal(day)} Sun of the {Ordinal(moon)} {(month % 2 == 1 ? "Astral" : "Umbral")} Moon";
    }

    internal static string Ordinal(int value)
    {
        var suffix = (value % 100) is 11 or 12 or 13 ? "th" : (value % 10) switch { 1 => "st", 2 => "nd", 3 => "rd", _ => "th" };
        return value + suffix;
    }

    internal static float Progress(long current, long needed) =>
        needed <= 0 ? 1 : Math.Clamp(current / (float)needed, 0, 1);

    internal static string TitleCase(string text)
    {
        if (string.IsNullOrEmpty(text) || char.IsUpper(text[0])) return text;
        var chars = text.ToCharArray();
        for (var i = 0; i < chars.Length; i++)
            if (i == 0 || chars[i - 1] is ' ' or '-') chars[i] = char.ToUpperInvariant(chars[i]);
        return new string(chars);
    }

    internal static StatLayout LayoutFor(uint classJobCategory) => classJobCategory switch
    {
        33 => StatLayout.Crafter,
        32 => StatLayout.Gatherer,
        _ => StatLayout.Combat,
    };

    /// <summary>The second resource pool beside HP: MP in combat, CP for crafters, GP for gatherers.</summary>
    internal static string PoolLabel(uint classJobCategory) => LayoutFor(classJobCategory) switch
    {
        StatLayout.Crafter => "CP",
        StatLayout.Gatherer => "GP",
        _ => "MP",
    };

    /// <summary>Base-param ids per section, in BaseParam.OrderPriority order (the sheet the game
    /// sorts its own attribute lists by; Determination 20 precedes Direct Hit Rate 23).</summary>
    internal static IReadOnlyList<(string Section, uint[] BaseParams)> Sections(StatLayout layout) => layout switch
    {
        StatLayout.Crafter => [("Crafting", [70, 71, 11]), ("Attributes", [1, 2, 3, 4, 5])],
        StatLayout.Gatherer => [("Gathering", [72, 73, 10]), ("Attributes", [1, 2, 3, 4, 5])],
        _ =>
        [
            ("Attributes", [1, 2, 3, 4, 5]),
            ("Offensive Properties", [27, 44, 22]),
            ("Defensive Properties", [21, 24]),
            ("Physical Properties", [20, 45]),
            ("Mental Properties", [33, 34, 46]),
            ("Role", [19, 6]),
        ],
    };

    /// <summary>Tenacity for tanks, Piety for healers; other roles have no emphasized role stat.</summary>
    internal static uint RoleStat(byte role) => role switch { 1 => 19u, 4 => 6u, _ => 0u };

    /// <summary>ClassJob.PrimaryStat (1 STR, 2 DEX, 4 INT, 5 MND) is already a BaseParam id.</summary>
    internal static bool Emphasized(uint baseParam, uint primaryStat, byte role) =>
        baseParam != 0 && (baseParam == primaryStat || baseParam == RoleStat(role));

    /// <summary>Which rows the classes page shows, and where. Base combat classes are folded into
    /// their jobs (they share one level), so each level appears once per job, as in the game.</summary>
    internal static JobSection? SectionFor(byte role, uint category, byte jobIndex, uint parent, uint id, bool limited, string abbreviation)
    {
        if (id == 0 || string.IsNullOrWhiteSpace(abbreviation)) return null;
        if (limited) return JobSection.Limited;
        if (category == 33) return JobSection.Hand;
        if (category == 32) return JobSection.Land;
        if (jobIndex == 0 && parent == id) return null;
        return RoleSection(role, category);
    }

    /// <summary>Combat section by the displayed row's own role. Roles are not inherited:
    /// Arcanist is a caster while Scholar is a healer.</summary>
    internal static JobSection? RoleSection(byte role, uint category) => role switch
    {
        1 => JobSection.Tank,
        4 => JobSection.Healer,
        2 => JobSection.Melee,
        3 => category == 31 ? JobSection.Magic : JobSection.Ranged,
        _ => null,
    };

    /// <summary>A job whose unlock quest is not complete is presented as its base class
    /// (same shared level) in the base class's own section.</summary>
    internal static bool ShowAsBaseClass(uint id, uint parent, bool jobUnlocked) =>
        parent != 0 && parent != id && !jobUnlocked;

    /// <summary>ParamGrow keeps a non-zero value at the final level, so the cap is the level
    /// whose following row is empty. Blue Mage's lower cap is not in any sheet.</summary>
    internal static bool IsMaxLevel(uint id, int level, long expToNextOfFollowingLevel) =>
        level > 0 && (expToNextOfFollowingLevel <= 0 || (id == BlueMage && level >= BlueMageCap));

    internal static string SectionName(JobSection section) => section switch
    {
        JobSection.Tank => "Tank",
        JobSection.Healer => "Healer",
        JobSection.Melee => "Melee DPS",
        JobSection.Ranged => "Physical Ranged DPS",
        JobSection.Magic => "Magical Ranged DPS",
        JobSection.Hand => "Disciples of the Hand",
        JobSection.Land => "Disciples of the Land",
        _ => "Limited Jobs",
    };

    /// <summary>Clamped list movement; an empty list has no selection.</summary>
    internal static int Move(int index, int delta, int count) =>
        count <= 0 ? -1 : Math.Clamp(index < 0 ? 0 : index + delta, 0, count - 1);

    /// <summary>Left/right on the equipment list: the same position in the other group.</summary>
    internal static int EquipmentJump(int index, int direction)
    {
        var count = EquipmentOrder.Length;
        if (index < 0) return 0;
        if (direction < 0) return index >= EquipmentHalf ? index - EquipmentHalf : index;
        return index < EquipmentHalf ? Math.Min(index + EquipmentHalf, count - 1) : index;
    }

    internal static string GearSetResult(int number, int result) => result < 0
        ? $"Gear set {number} can't be equipped right now. It may be unavailable in combat, during a duty or while performing another action."
        : $"Changing to gear set {number}…";
}

public enum StatLayout { Combat, Crafter, Gatherer }
public enum JobSection { Tank, Healer, Melee, Ranged, Magic, Hand, Land, Limited }
public enum CharacterPage { Equipment, Attributes, Jobs, GearSets }

/// <summary>Which native main-menu requests the ready character sheet can replace.</summary>
internal static class CharacterCommandPolicy
{
    internal static bool CanReplace(uint command, bool frameworkThread, bool enabled, bool ready,
        bool nativeBypass, bool nativeVisible, bool unlocked) =>
        command == CharacterMath.MainCommandCharacter && frameworkThread && enabled && ready &&
        !nativeBypass && !nativeVisible && unlocked;

    internal static bool KeepNativeBypass(bool visible, bool hasBeenVisible, bool openingExpired) =>
        visible || (!hasBeenVisible && !openingExpired);
}
