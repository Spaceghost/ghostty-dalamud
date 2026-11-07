using System.Numerics;
using Dalamud.Plugin.Services;
using Dalamud.Interface.Textures;
using Dalamud.Bindings.ImGui;
using XivHud.Items.Core;
using static XivHud.Style.IllustratedStyle;
namespace XivHud.Crafting;
internal sealed class ModuleWindow(ITextureProvider textures)
{
    internal bool Open, Preview;
    internal BagSnapshot Bags = BagSnapshot.Empty;
    internal RecipeEntry[] Recipes = [];
    private readonly Dictionary<uint, int> plan = [], samplePlan = [];
    private string search = "", job = "All";
    private uint selected;
    private int page, crafts = 1;
    private bool materials;
    private RecipeEntry[]? filteredSource;
    private RecipeEntry[] filtered = [];
    private string lastSearch = "", lastJob = "";
    private static readonly RecipeEntry[] Samples = [new(1, "Sample iron ingot", "Blacksmith", 10, 1, [new(2, "Sample iron ore", 3), new(3, "Sample fire shard", 1)])];
    internal void Clear() { Bags = BagSnapshot.Empty; plan.Clear(); samplePlan.Clear(); Open = Preview = false; search = ""; selected = 0; }
    internal void Draw(string error)
    {
        var recipes = Preview ? Samples : Recipes;
        var active = Preview ? samplePlan : plan;
        ImGui.PushStyleColor(ImGuiCol.WindowBg, V(Ink)); ImGui.PushStyleColor(ImGuiCol.Text, V(Ivory)); ImGui.PushStyleColor(ImGuiCol.Border, V(Gold));
        ImGui.SetNextWindowSize(new(840, 620), ImGuiCond.FirstUseEver);
        ImGui.SetNextWindowSizeConstraints(new(640, 560), new(float.MaxValue));
        var drew = ImGui.Begin(Preview ? "Crafting · SAMPLE###XivHud.Crafting" : "Crafting###XivHud.Crafting", ref Open);
        try
        {
            if (!drew) return;
            ImGui.TextColored(V(PaleGold), "WORKSHOP  /  CRAFTING");
            Rule(ImGui.GetWindowDrawList(), ImGui.GetCursorScreenPos() + new Vector2(0, 3), ImGui.GetContentRegionAvail().X, Gold, 1); ImGui.Dummy(new(0, 12));
            if (error.Length > 0 && !Preview) ImGui.TextWrapped(error);
            if (ImGui.Button(materials ? "Recipe browser" : $"Worklist ({active.Count})")) materials = !materials;
            ImGui.SameLine(); ImGui.TextDisabled("Session plan · quantities are number of crafts");
            if (materials) { DrawPlan(recipes, active); return; }
            if (ImGui.InputTextWithHint("##search", "Search recipe or ingredient", ref search, 160)) page = 0;
            if (ImGui.BeginCombo("Discipline", job))
            {
                foreach (var name in new[] { "All" }.Concat(recipes.Select(r => r.Job).Distinct().Order()))
                    if (ImGui.Selectable(name, job == name)) { job = name; page = 0; }
                ImGui.EndCombo();
            }
            if (filteredSource != recipes || lastSearch != search || lastJob != job)
            {
                filteredSource = recipes; lastSearch = search; lastJob = job;
                filtered = recipes.Where(r => (job == "All" || job == r.Job) && (r.Name.Contains(search.Trim(), StringComparison.OrdinalIgnoreCase)
                || r.Ingredients.Any(i => i.Name.Contains(search.Trim(), StringComparison.OrdinalIgnoreCase)))).ToArray();
            }
            var matches = filtered;
            page = Math.Clamp(page, 0, Math.Max(0, (matches.Length - 1) / 100));
            ImGui.Text($"{matches.Length} recipes · Page {page + 1}");
            ImGui.SameLine(); ImGui.BeginDisabled(page == 0); if (ImGui.Button("Previous")) page--; ImGui.EndDisabled();
            ImGui.SameLine(); ImGui.BeginDisabled((page + 1) * 100 >= matches.Length); if (ImGui.Button("Next")) page++; ImGui.EndDisabled();
            if (ImGui.BeginChild("recipes", new(0, -185), true))
            {
                if (matches.Length == 0) ImGui.TextDisabled(recipes.Length == 0 ? "Recipe data unavailable." : "No matching recipes.");
                foreach (var row in matches.Skip(page * 100).Take(100))
                    if (ImGui.Selectable($"{row.Name} · {row.Job} Lv.{row.Level}##{row.Id}", selected == row.Id)) selected = row.Id;
            }
            ImGui.EndChild();
            var detail = recipes.FirstOrDefault(r => r.Id == selected);
            if (detail is null) { ImGui.TextDisabled("Select a recipe to inspect materials and add crafts."); return; }
            if (detail.Icon != 0 && textures.GetFromGameIcon(new GameIconLookup(detail.Icon)).GetWrapOrDefault() is { } icon) { ImGui.Image(icon.Handle, new(36, 36)); ImGui.SameLine(); }
            ImGui.TextColored(V(Aether), $"{detail.Name} · Yield {detail.Yield} per craft");
            ImGui.TextWrapped(string.Join(" · ", detail.Ingredients.Select(i => $"{i.Name} ×{i.Amount}")));
            ImGui.SetNextItemWidth(140); ImGui.InputInt("Crafts", ref crafts); crafts = Math.Clamp(crafts, 1, Worklist.MaximumCrafts);
            ImGui.BeginDisabled(!active.ContainsKey(detail.Id) && active.Count >= Worklist.MaximumRecipes);
            if (ImGui.Button("Add to worklist")) active[detail.Id] = Math.Min(Worklist.MaximumCrafts, active.GetValueOrDefault(detail.Id) + crafts);
            ImGui.EndDisabled();
            ImGui.TextWrapped("Recipe catalogue includes locked recipes. Availability, specialist and unlock requirements must be checked in the native crafting log.");
        }
        finally { ImGui.End(); ImGui.PopStyleColor(3); }
    }
    private void DrawPlan(RecipeEntry[] recipes, Dictionary<uint, int> active)
    {
        if (ImGui.Button("Clear worklist")) active.Clear();
        if (active.Count == 0) { ImGui.TextDisabled("Add recipes to calculate a shared shopping list."); return; }
        if (ImGui.BeginChild("plan", new(0, 140), true))
            foreach (var row in recipes.Where(r => active.ContainsKey(r.Id)))
            {
                ImGui.PushID(row.Id.ToString());
                if (ImGui.SmallButton("Remove")) active.Remove(row.Id);
                ImGui.SameLine(); ImGui.TextUnformatted($"{row.Name} · {active.GetValueOrDefault(row.Id)} crafts · {(long)active.GetValueOrDefault(row.Id) * row.Yield} output");
                ImGui.PopID();
            }
        ImGui.EndChild();
        ImGui.TextWrapped("Direct ingredients only; subrecipes are not expanded. Owned combines usable NQ + HQ in four carried bags; collectables are excluded. Crystals and other storage are not counted; compare these separately.");
        var needs = Worklist.Materials(recipes, active, Preview ? BagSnapshot.Empty : Bags);
        if (ImGui.Button("Copy material list")) ImGui.SetClipboardText(string.Join("\n", needs.Select(i => $"{i.Name}: need {i.Required}, owned {i.Owned?.ToString() ?? "unknown"}, missing {i.Missing?.ToString() ?? "unknown"}")));
        if (ImGui.BeginChild("materials", new(0, 0), true))
            foreach (var item in needs)
                ImGui.TextUnformatted($"{item.Name} · Need {item.Required} · Owned {item.Owned?.ToString() ?? "?"} · Missing {item.Missing?.ToString() ?? "?"}");
        ImGui.EndChild();
    }
}
