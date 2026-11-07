using System.Numerics;
using Dalamud.Plugin.Services;
using Dalamud.Interface.Textures;
using Dalamud.Bindings.ImGui;
using XivHud.Items.Core;
using static XivHud.Style.IllustratedStyle;
namespace XivHud.Inventory;
internal sealed class ModuleWindow(ITextureProvider textures)
{
    internal bool Open, Preview;
    internal BagSnapshot Bags = BagSnapshot.Empty;
    private string search = "";
    private bool hq;
    private (int Bag, int Slot)? selected;
    private static readonly BagSnapshot Sample = new([
        new(1, "Sample potion", "Medicine", 0, 12, false, 1, 1, 1),
        new(2, "Sample iron ore", "Stone", 0, 24, true, 2, 3, 1)], 4, 140, 2);
    internal void Clear() { Bags = BagSnapshot.Empty; selected = null; search = ""; Open = Preview = false; }
    internal void Draw(string error)
    {
        ImGui.PushStyleColor(ImGuiCol.WindowBg, V(Ink)); ImGui.PushStyleColor(ImGuiCol.Text, V(Ivory)); ImGui.PushStyleColor(ImGuiCol.Border, V(Gold));
        ImGui.SetNextWindowSize(new(760, 520), ImGuiCond.FirstUseEver);
        ImGui.SetNextWindowSizeConstraints(new(600, 450), new(float.MaxValue));
        var drew = ImGui.Begin(Preview ? "Inventory · SAMPLE###XivHud.Inventory" : "Inventory###XivHud.Inventory", ref Open);
        try
        {
            if (!drew) return;
            ImGui.TextColored(V(PaleGold), "SATCHEL  /  INVENTORY");
            Rule(ImGui.GetWindowDrawList(), ImGui.GetCursorScreenPos() + new Vector2(0, 3), ImGui.GetContentRegionAvail().X, Gold, 1); ImGui.Dummy(new(0, 12));
            if (error.Length > 0 && !Preview) ImGui.TextWrapped(error);
            var snapshot = Preview ? Sample : Bags;
            ImGui.TextWrapped($"{snapshot.Occupied} / {snapshot.Capacity} slots · {snapshot.LoadedBags}/4 bags loaded");
            ImGui.InputTextWithHint("##search", "Search item name or category", ref search, 160);
            ImGui.SameLine(); ImGui.Checkbox("HQ only", ref hq);
            if (!snapshot.Complete) ImGui.TextWrapped("Waiting for all four carried bags. Saddlebag, armoury, crystals and retainers are outside this view.");
            var rows = snapshot.Search(search, hq);
            if (ImGui.BeginChild("items", new(0, -110), true))
            {
                if (rows.Count == 0) ImGui.TextDisabled(snapshot.Complete ? "No matching items." : "Inventory not ready.");
                foreach (var item in rows)
                    if (ImGui.Selectable($"{item.Name}{(item.HighQuality ? "  HQ" : "")}   ×{item.Quantity}   · Bag {item.Bag}, slot {item.Slot}##{item.Bag}:{item.Slot}", selected == (item.Bag, item.Slot)))
                        selected = (item.Bag, item.Slot);
            }
            ImGui.EndChild();
            var detail = snapshot.Items.FirstOrDefault(i => selected == (i.Bag, i.Slot));
            if (detail is not null)
            {
                if (detail.Icon != 0 && textures.GetFromGameIcon(new GameIconLookup(detail.Icon)).GetWrapOrDefault() is { } icon) { ImGui.Image(icon.Handle, new(36, 36)); ImGui.SameLine(); }
                ImGui.TextColored(V(Aether), detail.Name + (detail.HighQuality ? " · High quality" : "") + (detail.Collectable ? " · Collectable" : ""));
                ImGui.TextWrapped($"{detail.Category} · Item level {detail.ItemLevel} · ID {detail.ItemId}");
                ImGui.TextWrapped($"Total in carried bags (NQ + HQ): {snapshot.Count(detail.ItemId)}");
                if (ImGui.Button("Copy item name")) ImGui.SetClipboardText(detail.Name);
            }
            else ImGui.TextDisabled("Select an item for details.");
        }
        finally { ImGui.End(); ImGui.PopStyleColor(3); }
    }
}
