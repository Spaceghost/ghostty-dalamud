using FFXIVClientStructs.FFXIV.Client.System.String;
using FFXIVClientStructs.FFXIV.Client.UI;

namespace XivHud.Chat;

internal static class NativeChatInput
{
    internal static bool Supported => typeof(UIModule).Assembly.ManifestModule.ModuleVersionId is var id
        && (id == new Guid("43514195-87af-4f1b-86af-fa502aeeada1") || id == new Guid("7fda2a82-4ca8-49d0-9687-4c8eac011509"));
    internal static unsafe void Send(string line)
    {
        if (!Supported) throw new InvalidOperationException("Chat input bindings are unavailable");
        var ui = UIModule.Instance(); if (ui == null) throw new InvalidOperationException("Game chat is not ready");
        var text = Utf8String.FromString(line); if (text == null) throw new InvalidOperationException("Chat allocation failed");
        try
        {
            text->SanitizeString((AllowedEntities)0x27F, null);
            if (!string.Equals(text->ToString(), line, StringComparison.Ordinal)) throw new InvalidOperationException("The game would change these characters; edit the message before sending");
            ui->ProcessChatBoxEntry(text, 0, false);
        }
        finally { text->Dtor(true); }
    }
}
