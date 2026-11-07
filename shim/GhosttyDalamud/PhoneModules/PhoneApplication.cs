using System;
using System.Collections.Generic;
using System.Threading.Tasks;

namespace GhosttyDalamud.PhoneModules;

// These are ordinary modules in this assembly. Only GhosttyDalamud.Plugin is
// discoverable by Dalamud; no separate HUD, Chat, Inventory or Grimoire plugin.
internal sealed class PhoneApplication
{
    private XivHud.Plugin.ControllerBroker? controller;
    private XivHud.Journal.Plugin? journal;
    private XivHud.Character.Plugin? character;
    private XivHud.Chat.Plugin? chat;
    private XivHud.Inventory.Plugin? inventory;
    private XivHud.Crafting.Plugin? crafting;
    private XivSpell.Plugin? grimoire;
    private bool disposed;

    internal PhoneApplication()
    {
        try
        {
            foreach (string command in new[] { "/xivjournal", "/xivcharacter", "/xivchat", "/xivinventory", "/xivcrafting", "/xivspell" })
                if (Plugin.Commands.Commands.ContainsKey(command))
                    throw new InvalidOperationException($"The phone includes {command}. Disable its separate plugin before loading the consolidated phone plugin.");
            // Register the controller provider before its local consumers.
            controller = Plugin.Pi.Create<XivHud.Plugin.ControllerBroker>() ?? throw new InvalidOperationException("Phone controller services unavailable");
            journal = Plugin.Pi.Create<XivHud.Journal.Plugin>() ?? throw new InvalidOperationException("Phone Journal unavailable");
            character = Plugin.Pi.Create<XivHud.Character.Plugin>() ?? throw new InvalidOperationException("Phone Character unavailable");
            chat = Plugin.Pi.Create<XivHud.Chat.Plugin>() ?? throw new InvalidOperationException("Phone Correspondence unavailable");
            inventory = Plugin.Pi.Create<XivHud.Inventory.Plugin>() ?? throw new InvalidOperationException("Phone Inventory unavailable");
            crafting = Plugin.Pi.Create<XivHud.Crafting.Plugin>() ?? throw new InvalidOperationException("Phone Workshop unavailable");
            grimoire = Plugin.Pi.Create<XivSpell.Plugin>() ?? throw new InvalidOperationException("Grimoire services unavailable");
        }
        catch { _ = DisposeAsync(); throw; }
    }

    internal bool Open(string name)
    {
        if (disposed) return false;
        string? command = name switch {
            "journal" => "/xivjournal open", "character" => "/xivcharacter open",
            "chat" => "/xivchat open", "inventory" => "/xivinventory open",
            "crafting" => "/xivcrafting open", "grimoire" => "/xivspell book", _ => null };
        if (command == null) return false;
        return Plugin.Commands.ProcessCommand(command);
    }

    internal async Task DisposeAsync()
    {
        if (disposed) return;
        disposed = true;
        // Stop sources and input before removing the core's capture/remap hooks.
        var errors = new List<Exception>();
        void Stop(Action action) { try { action(); } catch (Exception error) { errors.Add(error); } }
        void StopSources() {
            Stop(() => grimoire?.Dispose()); Stop(() => crafting?.Dispose());
            Stop(() => inventory?.Dispose()); Stop(() => chat?.Dispose());
        }
        if (Plugin.GameFramework.IsInFrameworkUpdateThread) StopSources();
        else await Plugin.GameFramework.RunOnFrameworkThread(StopSources).ConfigureAwait(false);
        var pending = new List<Task>();
        if (character != null) Stop(() => pending.Add(character.DisposeAsync().AsTask()));
        if (journal != null) Stop(() => pending.Add(journal.DisposeAsync().AsTask()));
        try { await Task.WhenAll(pending).ConfigureAwait(false); }
        catch (Exception error) { errors.Add(error); }
        finally { Stop(() => controller?.Dispose()); }
        if (errors.Count != 0) throw new AggregateException("Phone module shutdown errors", errors);
    }

    internal static async ValueTask Shutdown(PhoneApplication? application, Action finish)
    {
        try { if (application != null) await application.DisposeAsync().ConfigureAwait(false); }
        finally {
            if (Plugin.GameFramework.IsInFrameworkUpdateThread) finish();
            else await Plugin.GameFramework.RunOnFrameworkThread(finish).ConfigureAwait(false);
        }
    }
}
