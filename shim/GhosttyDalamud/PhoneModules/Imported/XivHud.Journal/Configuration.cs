using Dalamud.Configuration;

namespace XivHud.Journal;

[Serializable]
public sealed class Configuration : IPluginConfiguration
{
    public int Version { get; set; } = 1;
    public bool ReplaceJournal { get; set; } = true;
    public float Scale { get; set; } = 1;
    public bool DarkPaper { get; set; }
    public bool Ornament { get; set; } = true;
    public bool ShowToolbarEntry { get; set; } = true;
    public bool WindowHostEnabled { get; set; }
    public bool UseGhosttyWorldWindows { get; set; }
    public bool NativeWindowEnabled { get; set; }
    public string WindowHostPlacement { get; set; } = "Hud";
    public string ControllerLabels { get; set; } = "PlayStation";
    public bool SwapConfirmBack { get; set; }
    public HashSet<uint> Bookmarks { get; set; } = [];
    public bool TrackerEnabled { get; set; }
    public bool TrackerLocked { get; set; } = true;
    public bool TrackerBookmarks { get; set; }
    public int TrackerLimit { get; set; } = 3;
    public System.Numerics.Vector2 TrackerAnchor { get; set; } = new(.98f, .58f);
}
