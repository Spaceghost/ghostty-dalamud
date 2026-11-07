namespace XivHud.Journal;

public sealed record JournalEntry(
    uint Id, string Name, int Level, string Category, string Genre,
    bool Tracked, bool Priority, int Sequence, IReadOnlyList<string> Objectives,
    string Summary, uint IconId, bool Hidden = false, bool ReadyToComplete = false);
