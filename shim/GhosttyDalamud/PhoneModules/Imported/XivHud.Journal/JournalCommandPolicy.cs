namespace XivHud.Journal;

/// <summary>Which native main-menu requests the ready accepted-quest book can replace.</summary>
internal static class JournalCommandPolicy
{
    internal static bool CanReplace(uint command, bool frameworkThread, bool enabled, bool ready,
        bool nativeBypass, bool nativeVisible, bool supportedMode, bool unlocked) =>
        command == 4 && frameworkThread && enabled && ready && !nativeBypass &&
        !nativeVisible && supportedMode && unlocked;

    internal static bool KeepNativeBypass(bool visible, bool hasBeenVisible, bool openingExpired) =>
        visible || (!hasBeenVisible && !openingExpired);
}
