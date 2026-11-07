using FFXIVClientStructs.FFXIV.Client.UI;
using FFXIVClientStructs.FFXIV.Component.GUI;

namespace XivSpell;

// One category-hide operation for this UI generation. Unlike toggling visible
// addons every frame, this also covers chat windows created after acquisition.
internal sealed unsafe class NativeChatSuppression : IDisposable
{
    private readonly ChatVisibilityLease lease = new();

    public void Update(bool loggedIn)
    {
        var module = UIModule.Instance();
        var atk = module == null ? null : module->GetRaptureAtkModule();
        var manager = atk == null ? null : &atk->RaptureAtkUnitManager;
        lease.Reconcile(new((nint)module, (nint)manager));
        if (!loggedIn) { Release(module, manager); lease.Drop(); return; }
        if (lease.IsHeld || module == null || manager == null || !module->IsUIReady() ||
            (manager->Flags & AtkUnitManagerFlags.Unk40) == 0) return;
        lease.TryAcquire(new((nint)module, (nint)manager), () => { module->ToggleUi(UiFlags.Chat, false, true); return true; });
    }

    private void Release(UIModule* module, RaptureAtkUnitManager* manager)
    {
        if (manager == null || (manager->Flags & AtkUnitManagerFlags.Unk40) == 0) return;
        lease.Release(new((nint)module, (nint)manager), () => module->ToggleUi(UiFlags.Chat, true, true));
    }

    public void Dispose()
    {
        var module = UIModule.Instance();
        var atk = module == null ? null : module->GetRaptureAtkModule();
        Release(module, atk == null ? null : &atk->RaptureAtkUnitManager);
        lease.Drop();
    }
}
