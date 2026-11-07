using Dalamud.Plugin.Services;
using FFXIVClientStructs.FFXIV.Client.Game;

namespace XivSpell;

internal readonly record struct SpellAppearance(uint Action, uint Icon, string Name)
{
    internal static unsafe SpellAppearance? Resolve(IDataManager data, Card? card, uint performedAction = 0)
    {
        var action = performedAction != 0 ? performedAction : card?.Action ?? 0;
        if (action == 0) return null;
        if (performedAction == 0 && ActionManager.Instance() is var manager && manager != null)
            action = manager->GetAdjustedActionId(action);
        if (!data.GetExcelSheet<Lumina.Excel.Sheets.Action>().TryGetRow(action, out var row) || row.Icon == 0) return null;
        return new(action, row.Icon, row.Name.ToString());
    }
}
