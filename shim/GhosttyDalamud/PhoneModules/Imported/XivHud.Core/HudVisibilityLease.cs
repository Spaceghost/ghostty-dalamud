namespace XivHud.Core;

/// <summary>Both native owners must match before a suppression can be restored.</summary>
public readonly record struct HudModuleIdentity(nint Module, nint Manager)
{
    public bool IsValid => Module != 0 && Manager != 0;
}

/// <summary>
/// Tracks one native HUD suppression operation independently of game pointers.
/// The service serializes calls on the framework thread, validates native
/// readiness, and supplies the actual acquire/restore operations. This policy
/// never dereferences an identity or changes persisted HUD configuration.
/// </summary>
public sealed class HudVisibilityLease
{
    // UiFlags.Hud | Nameplates | Chat | ActionBars. Shortcuts and TargetInfo
    // are deliberately excluded because they also suppress UI key handling.
    public const int Mask = 30;

    public HudModuleIdentity Identity { get; private set; }
    public bool IsHeld => Identity.IsValid;

    /// <summary>
    /// Returns true only for a newly acquired lease. Failed or throwing native
    /// operations do not grant ownership; repeated acquisition is a no-op.
    /// </summary>
    public bool TryAcquire(HudModuleIdentity current, Func<bool> acquire)
    {
        ArgumentNullException.ThrowIfNull(acquire);
        Reconcile(current);
        if (!current.IsValid || IsHeld) return false;
        if (!acquire()) return false;
        Identity = current;
        return true;
    }

    /// <summary>
    /// Releases once only through the same valid native owners. Temporary
    /// unavailability keeps the pending lease, while a concrete replacement
    /// retires it. Ownership is forgotten before calling restore so an error
    /// cannot cause a second native decrement on a later update/shutdown.
    /// </summary>
    public bool Release(HudModuleIdentity current, Action restore)
    {
        ArgumentNullException.ThrowIfNull(restore);
        Reconcile(current);
        if (!current.IsValid || !IsHeld) return false;
        Drop();
        restore();
        return true;
    }

    /// <summary>
    /// Do not touch an absent owner. A different valid pair proves that the old
    /// lease can no longer be restored through the currently available module.
    /// </summary>
    public void Reconcile(HudModuleIdentity current)
    {
        if (current.IsValid && IsHeld && current != Identity) Drop();
    }

    /// <summary>
    /// Final teardown when no valid native owner remains. This performs no
    /// restore; callers should attempt Release with a validated owner first.
    /// </summary>
    public void Drop() => Identity = default;
}
