using Dalamud.Plugin.Services;
using FFXIVClientStructs.FFXIV.Client.Game;
using Lumina.Excel.Sheets;
using XivHud.Items.Core;
namespace XivHud.Items.Dalamud;

/// <summary>Framework-thread reads only. Never retains or changes game inventory pointers.</summary>
public sealed unsafe class ItemData(IDataManager data)
{
    private readonly Dictionary<uint, (string Name, string Category, uint Icon, int Level)> cache = [];
    public static bool Supported => typeof(InventoryManager).Assembly.ManifestModule.ModuleVersionId is var id
        && (id == new Guid("43514195-87af-4f1b-86af-fa502aeeada1") || id == new Guid("7fda2a82-4ca8-49d0-9687-4c8eac011509"));
    public BagSnapshot Read()
    {
        if (!Supported) return BagSnapshot.Empty;
        var manager = InventoryManager.Instance();
        if (manager == null) return BagSnapshot.Empty;
        List<ItemStack> rows = []; int loaded = 0, capacity = 0, occupied = 0;
        for (var bag = 0; bag < 4; bag++)
        {
            var container = manager->GetInventoryContainer((InventoryType)bag);
            if (container == null || !container->IsLoaded || container->Items == null || container->Size is < 0 or > 140) continue;
            loaded++; capacity += container->Size;
            for (var slot = 0; slot < container->Size; slot++)
            {
                var item = container->GetInventorySlot(slot);
                if (item == null || item->ItemId == 0 || item->Quantity <= 0) continue;
                occupied++;
                var id = item->ItemId;
                if (!cache.TryGetValue(id, out var info))
                {
                    var row = data.GetExcelSheet<Item>().GetRowOrDefault(id);
                    info = (row?.Name.ExtractText() ?? $"Item {id}", row?.ItemUICategory.ValueNullable?.Name.ExtractText() ?? "Unknown", row?.Icon ?? 0, (int)(row?.LevelItem.RowId ?? 0));
                    cache[id] = info;
                }
                rows.Add(new(id, info.Name, info.Category, info.Icon, (uint)item->Quantity, (item->Flags & InventoryItem.ItemFlags.HighQuality) != 0, bag + 1, slot + 1, info.Level, item->IsCollectable()));
            }
        }
        return new(rows, loaded, capacity, occupied);
    }
    public RecipeEntry[] Recipes()
    {
        List<RecipeEntry> rows = [];
        foreach (var row in data.GetExcelSheet<Recipe>())
        {
            if (row.ItemResult.RowId == 0 || row.AmountResult == 0 || row.ItemResult.ValueNullable is not { } result) continue;
            List<Ingredient> ingredients = [];
            for (var i = 0; i < row.Ingredient.Count; i++)
                if (row.Ingredient[i].RowId != 0 && row.AmountIngredient[i] > 0)
                    ingredients.Add(new(row.Ingredient[i].RowId, row.Ingredient[i].ValueNullable?.Name.ExtractText() ?? $"Item {row.Ingredient[i].RowId}", row.AmountIngredient[i]));
            rows.Add(new(row.RowId, result.Name.ExtractText(), row.CraftType.ValueNullable?.Name.ExtractText() ?? "Craft", row.RecipeLevelTable.ValueNullable?.ClassJobLevel ?? 0, row.AmountResult, ingredients, result.Icon));
        }
        return rows.OrderBy(i => i.Name, StringComparer.OrdinalIgnoreCase).ThenBy(i => i.Id).ToArray();
    }
}
