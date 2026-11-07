using Dalamud.Configuration;

namespace XivHud.Chat;

[Serializable]
public sealed class Configuration : IPluginConfiguration
{
    public int Version { get; set; } = 1;
    public bool DarkPaper { get; set; }
    public bool Ornament { get; set; } = true;
    public bool Enabled { get; set; }
    public bool Notifications { get; set; } = true;
    public bool NotifyTells { get; set; } = true;
    public bool NotifyErrors { get; set; } = true;
    public bool NotifyQuests { get; set; } = true;
    public bool NotifyNormal { get; set; }
}
