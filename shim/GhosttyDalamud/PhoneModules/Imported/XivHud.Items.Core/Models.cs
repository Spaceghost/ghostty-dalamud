namespace XivHud.Items.Core;

public sealed record ItemStack(uint ItemId, string Name, string Category, uint Icon, uint Quantity, bool HighQuality, int Bag, int Slot, int ItemLevel, bool Collectable = false);
public sealed record BagSnapshot(IReadOnlyList<ItemStack> Items, int LoadedBags, int Capacity, int Occupied)
{
    public bool Complete => LoadedBags == 4;
    public static BagSnapshot Empty { get; } = new([], 0, 0, 0);
    public IReadOnlyList<ItemStack> Search(string text, bool hqOnly = false) => Items
        .Where(i => (!hqOnly || i.HighQuality) && (i.Name.Contains(text.Trim(), StringComparison.OrdinalIgnoreCase)
            || i.Category.Contains(text.Trim(), StringComparison.OrdinalIgnoreCase)))
        .OrderBy(i => i.Name, StringComparer.OrdinalIgnoreCase).ThenBy(i => i.Bag).ThenBy(i => i.Slot).ToArray();
    public long UsableCount(uint id) => Items.Where(i => i.ItemId == id && !i.Collectable).Sum(i => (long)i.Quantity);
    public long Count(uint id) => Items.Where(i => i.ItemId == id).Sum(i => (long)i.Quantity);
}
public sealed record Ingredient(uint ItemId, string Name, int Amount);
public sealed record RecipeEntry(uint Id, string Name, string Job, int Level, int Yield, IReadOnlyList<Ingredient> Ingredients, uint Icon = 0);
public sealed record MaterialNeed(uint ItemId, string Name, long Required, long? Owned)
{
    public long? Missing => Owned is { } owned ? Math.Max(0, Required - owned) : null;
}
public static class Worklist
{
    public const int MaximumCrafts = 999;
    public const int MaximumRecipes = 100;
    // Quantities are craft counts, not output counts. Aggregate before subtracting shared stock.
    public static IReadOnlyList<MaterialNeed> Materials(IEnumerable<RecipeEntry> recipes, IReadOnlyDictionary<uint, int> plan, BagSnapshot bags)
    {
        var needs = new Dictionary<uint, (string Name, long Amount)>();
        foreach (var recipe in recipes)
        {
            if (!plan.TryGetValue(recipe.Id, out var count) || count <= 0) continue;
            foreach (var item in recipe.Ingredients)
            {
                if (item.ItemId == 0 || item.Amount <= 0) continue;
                needs.TryGetValue(item.ItemId, out var old);
                needs[item.ItemId] = (item.Name, old.Amount + (long)item.Amount * Math.Min(count, MaximumCrafts));
            }
        }
        return needs.Select(i => new MaterialNeed(i.Key, i.Value.Name, i.Value.Amount, bags.Complete && i.Key > 19 ? bags.UsableCount(i.Key) : null))
            .OrderBy(i => i.Name, StringComparer.OrdinalIgnoreCase).ToArray();
    }
}
