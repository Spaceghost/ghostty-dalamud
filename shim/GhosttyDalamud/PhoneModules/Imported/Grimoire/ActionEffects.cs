using System.Collections.Concurrent;
using System.Numerics;
using Dalamud.Hooking;
using Dalamud.Plugin.Services;
using FFXIVClientStructs.FFXIV.Client.Game.Character;
using FFXIVClientStructs.FFXIV.Client.Game.Object;

namespace XivSpell;

internal sealed unsafe class ActionEffects : IDisposable
{
    internal readonly record struct Effect(uint Caster, uint Action, ushort Sequence);
    internal readonly ConcurrentQueue<Effect> Received = new();
    private delegate void Receive(uint caster, Character* character, Vector3* position,
        ActionEffectHandler.Header* header, ActionEffectHandler.TargetEffects* effects, GameObjectId* targets);
    private readonly Hook<Receive> hook;
    internal ActionEffects(IGameInteropProvider interop)
    {
        hook = interop.HookFromAddress<Receive>((nint)ActionEffectHandler.MemberFunctionPointers.Receive, Detour);
        hook.Enable();
    }
    private void Detour(uint caster, Character* character, Vector3* position,
        ActionEffectHandler.Header* header, ActionEffectHandler.TargetEffects* effects, GameObjectId* targets)
    {
        try {
            if (header != null && header->ActionType == 1 && header->SourceSequence != 0) {
                Received.Enqueue(new(caster, header->ActionId, header->SourceSequence));
                while (Received.Count > 256) Received.TryDequeue(out _);
            }
        } catch { /* Never let observer failures cross the native callback. */ }
        finally { hook.Original(caster, character, position, header, effects, targets); }
    }
    public void Dispose() => hook.Dispose();
}
