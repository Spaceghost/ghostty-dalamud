# Phone shell

The phone shell lives inside `GhosttyDalamud`, using the existing Nelua core,
embedded Lua VM, world renderer and native-core loader. Its policy is
`lua/phone.lua`; the game-facing orchestration is `core/app/phone.nelua`.
There is no additional plugin for the shell.

This is an implementation of the phone shell, **not yet a complete migration
of FFXIV's non-combat UI or xivspell**. It has host-side tests and has not been
built for Windows or playtested in game in this change.

## Using it

* `/phone` or `/phone open`: summon the tomestone pose and open the shell.
  Existing terminal tabs, floating terminals and native terminal windows join
  the world projection. The launcher offers Terminal, Chat and Settings.
* `/phone close`: put it away; sessions remain alive. After enabling phone
  mode, the existing terminal toggle chord also opens/closes the phone.
* `/phone hud`: phase the focused projection onto the 2D HUD, using the
  existing world-to-screen spring and pointer mapping.
* `/phone world`: phase that panel back into the world.
* `/phone off`: release phone layout and return to ordinary world-panel mode.
* `/phone status`: log whether the shell is off, closed or open.
* `/phone reload`: run the existing Lua reload with full hook/pose cleanup,
  retaining the shell's open/closed intent after a successful reload.

`/term phone ...` is also available. Existing user copies of `init.lua` can
add `['/phone'] = 'phone'` to `host.verb_commands` to register the short alias.
The shipped configuration already includes it.

## Placement and interruptions

Panels unfold from an approximate device position into rows in front of the
character. Placement follows the character's heading, independently of the
camera, and accommodates different panel sizes. The origin is currently
character-relative, not attached to a hand bone. Existing world anchors are
overridden while phone mode is enabled and retained for when it is disabled.

Phone mode explicitly opts into the existing local tomestone animation while
the device is out, restoring the previous animation settings when put away.
It does not lock movement. Combat, a mount, a blocked scene, zoning, logout
or loss of the active core closes it. It stays closed until summoned again.
Reload, disable and unload release the pose through the common teardown.

Lua tuning is under `CONFIG.phone`: `duration`, `distance`, `height`, `columns`,
`gap`, `pixels_per_yalm`, `pose` and `reduce_motion`. `enabled` defaults to
false until `/phone` is used. Native changes use the existing
`ghostty_loader.dll` file watcher and `/term reload-core` path.

## What is actually projected

| Surface | Current implementation |
| --- | --- |
| Phone launcher | ImGui draw-list adoption into a world panel |
| Terminal tabs, floating and native terminal windows | Existing sessions moved into world panels |
| Ghostty Settings, Ask, Agents, Netlab, window picker | Automatically adopted while phone mode is enabled |
| Game chat | Existing reconstructed chat panel, opened from the launcher |
| Other plugins' ImGui windows | Existing manual `/window adopt NAME` mechanism |
| Native inventory, equipment, map, journal, crafting, shops, settings, dialogue | No general native renderer/input adapter implemented |
| xivspell spellbook and command bar | Still in the separate xivspell project; not merged |

Adopted ImGui source windows must continue laying themselves out within the
viewport because ImGui culls off-screen content. The existing RenderPre hook
removes their source draw lists from presentation and the world renderer
projects a captured copy. Moving the source coordinates off-screen would
produce blank projections. See [ADOPT.md](ADOPT.md).

The complete migration needs a native game UI capture/render adapter and
inverse pointer/controller routing, including child windows and modal menus.
An addon being enumerable or hideable does not supply its rendered texture.
Unsupported native windows are therefore not hidden by this shell.
Each native adapter must demonstrate rendering and interaction before taking
ownership of its original HUD surface, and release ownership on reload,
failure, combat and logout. Combat HUD elements remain under game control.

Consolidating xivspell also requires bringing its spell runtime into the
embedded Lua VM: its current Lua modules depend on Neovim APIs and its C#
adapter owns a separate listener and plugin configuration. Adopting its
window alone would not satisfy the single-plugin/runtime objective.

## Validation

`tests/test_phone.lua` checks placement, unfolding, interrupted closure,
mixed-size spacing, reduced motion, pose opt-out and restoration of animation
settings. `tests/test_phone.nelua` checks the real embedded Lua boundary,
balanced stacks on errors and repeated policy reloads. Both are included in
`tests/run.sh`. Target rendering, input and animation still need in-game
validation.
