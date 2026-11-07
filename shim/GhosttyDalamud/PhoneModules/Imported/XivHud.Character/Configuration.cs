using Dalamud.Configuration;

namespace XivHud.Character;

[Serializable]
public sealed class Configuration : IPluginConfiguration
{
    public int Version { get; set; } = 1;
    public bool ReplaceCharacter { get; set; } = true;
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
    public int LastPage { get; set; }
}
