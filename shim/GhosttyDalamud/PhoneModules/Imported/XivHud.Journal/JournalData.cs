using Dalamud.Plugin.Services;
using Dalamud.Utility;
using FFXIVClientStructs.FFXIV.Client.Game;
using Lumina.Excel;
using Quest = Lumina.Excel.Sheets.Quest;

namespace XivHud.Journal;

/// <summary>Framework-thread snapshots of accepted normal quests; no native pointers escape a read.</summary>
public sealed unsafe class JournalData(IDataManager data)
{
    private readonly Dictionary<uint, QuestInfo> cache = [];
    private readonly record struct QuestInfo(string Name, int Level, string Category, string Genre,
        uint Icon, JournalTodo[] Todos);

    /// <remarks>Call on the framework thread while logged in, normally every 250–500 ms.
    /// Leves and completed-quest history remain available in the original Journal.</remarks>
    public IReadOnlyList<JournalEntry> Read()
    {
        var manager = QuestManager.Instance();
        if (manager == null) return [];
        var tracked = new HashSet<int>();
        foreach (ref var entry in manager->TrackedQuests)
            if (entry.QuestType == 1) tracked.Add(entry.Index);

        var result = new List<JournalEntry>(30);
        var quests = manager->NormalQuests;
        for (var i = 0; i < quests.Length; i++)
        {
            ref var work = ref quests[i];
            if (work.QuestId == 0) continue;
            var id = JournalText.QuestRowBase + work.QuestId;
            var info = Info(id);
            var objectives = JournalText.CurrentObjectives(info.Todos, work.Sequence);
            // Raw _SEQ_ narrative rows do not have a verified mapping to the live sequence.
            // Do not display an arbitrary/future story paragraph as a summary.
            result.Add(new JournalEntry(id, info.Name, info.Level, info.Category, info.Genre,
                tracked.Contains(i), work.IsPriority, work.Sequence, objectives, string.Empty,
                info.Icon, work.IsHidden, work.Sequence == byte.MaxValue));
        }
        return result.OrderByDescending(q => q.Priority).ThenByDescending(q => q.Tracked)
            .ThenBy(q => q.Name, StringComparer.CurrentCultureIgnoreCase).ThenBy(q => q.Id).ToArray();
    }

    private QuestInfo Info(uint id)
    {
        if (cache.TryGetValue(id, out var found)) return found;
        var row = data.GetExcelSheet<Quest>().GetRowOrDefault(id);
        if (row is not { } quest)
            return new QuestInfo($"Quest {id & 0xFFFF}", 0, "Quests", "", 71001, []);
        var genre = quest.JournalGenre.ValueNullable;
        var category = genre?.JournalCategory.ValueNullable;
        var texts = TodoTexts(quest.Id.ExtractText());
        var todos = new List<JournalTodo>();
        for (var i = 0; i < quest.TodoParams.Count; i++)
        {
            var sequence = quest.TodoParams[i].ToDoCompleteSeq;
            if (sequence != 0 && texts.TryGetValue(i, out var text)) todos.Add(new JournalTodo(sequence, text));
        }
        var name = quest.Name.ExtractText();
        var info = new QuestInfo(string.IsNullOrWhiteSpace(name) ? $"Quest {id & 0xFFFF}" : name,
            quest.ClassJobLevel.Count > 0 ? quest.ClassJobLevel[0] : 0,
            category is { } c ? c.Name.ExtractText() : "Quests",
            genre is { } g ? g.Name.ExtractText() : "",
            quest.Icon != 0 ? quest.Icon : 71001, todos.ToArray());
        cache[id] = info;
        return info;
    }

    private Dictionary<int, string> TodoTexts(string key)
    {
        var result = new Dictionary<int, string>();
        var path = JournalText.SheetPath(key);
        if (path == null) return result;
        try
        {
            var raw = data.Excel.GetRawSheet(path, data.Language.ToLumina());
            if (raw.Columns.Count < 2) return result;
            foreach (var row in new ExcelSheet<RawRow>(raw))
            {
                if (JournalText.TodoIndex(row.ReadStringColumn(0).ExtractText()) is not { } index) continue;
                var text = row.ReadStringColumn(1).ExtractText();
                if (!string.IsNullOrWhiteSpace(text)) result[index] = text;
            }
        }
        catch
        {
            // Missing or changed text sheets must not make the accepted-quest list disappear.
            // Native details remain available; no future-step text is substituted.
        }
        return result;
    }
}
