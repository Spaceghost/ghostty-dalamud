namespace XivHud.Chat.Core;

public enum NotificationKind { Info, Message, Quest, Error }
public sealed record Notice(long Id, string Source, string Title, string Text, NotificationKind Kind, long CreatedAt, int Count = 1, ChatChannel? Channel = null);
public sealed class NotificationStore
{
    private readonly object gate = new();
    private readonly List<Notice> notices = [];
    private readonly List<Notice> archive = [];
    private long sequence;
    public const int Capacity = 64;
    public const long Lifetime = 7000;
    public void Push(string source, string title, string text, NotificationKind kind, long now, ChatChannel? channel = null)
    {
        source = ChatStore.Clean(source, 64); title = ChatStore.Clean(title, 100); text = ChatStore.Clean(text, 500);
        if (string.IsNullOrWhiteSpace(text)) return;
        lock (gate)
        {
            Expire(now);
            var duplicate = notices.FindIndex(x => x.Source == source && x.Title == title && x.Text == text && x.Kind == kind && now >= x.CreatedAt && now - x.CreatedAt <= 2000);
            if (duplicate >= 0)
            {
                var old = notices[duplicate]; var updated = old with { CreatedAt = now, Count = Math.Min(999, old.Count + 1) }; notices[duplicate] = updated;
                var index = archive.FindIndex(x => x.Id == old.Id); if (index >= 0) archive[index] = updated; return;
            }
            var notice = new Notice(++sequence, source, title, text, kind, now, 1, channel);
            archive.Add(notice); while (archive.Count > 128) archive.RemoveAt(0);
            if (notices.Count >= Capacity)
            {
                var victim = notices.OrderBy(x => x.Kind).ThenBy(x => x.CreatedAt).First();
                if (victim.Kind > kind) return;
                notices.Remove(victim);
            }
            notices.Add(notice);
        }
    }
    public IReadOnlyList<Notice> Active(long now, int maximum = 3)
    {
        lock (gate) { Expire(now); return notices.OrderByDescending(x => x.Kind).ThenByDescending(x => x.CreatedAt).Take(Math.Clamp(maximum, 0, Capacity)).ToArray(); }
    }
    public void Dismiss(long id) { lock (gate) notices.RemoveAll(x => x.Id == id); }
    public IReadOnlyList<Notice> History() { lock (gate) return archive.OrderByDescending(x => x.CreatedAt).ToArray(); }
    public void Clear() { lock (gate) { notices.Clear(); archive.Clear(); } }
    private void Expire(long now) => notices.RemoveAll(x => now < x.CreatedAt || now - x.CreatedAt >= Lifetime);
}
