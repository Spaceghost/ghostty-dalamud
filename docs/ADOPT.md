# Flat windows in the world ("adopt")

**Status: host tests only. Not yet observed in game.** Nothing below has run
inside FFXIV; the frame ordering, the hooks and the shim forwarders are
designed against Dear ImGui 1.88 (Dalamud's cimgui) and Dalamud's API, and
checked only against fakes (`tests/test_adopt.nelua`, `tests/test_adopt_app.nelua`).

Other plugins' ImGui windows (Mappy's map, ChatTwo, any window) and the
game's own chat log can leave the flat UI and become world panels: a pet by
default, pinnable, Alt + draggable and closable like a terminal. Closing one
("back to UI", its x, `/window release`, or popping it in) puts it back
exactly where it came from.

```
/window adopt mappy        Mappy's map as a pet (also automatic, see below)
/window adopt chat2        ChatTwo's main window ("Chat 2###chat2")
/window adopt chat         the game's chat log (ChatLog), drawn by ghostty
/window adopt TITLE        any ImGui window by its name
/window release [NAME]     back to the flat UI (no name: the focused one, else the newest)
/window adopted            what is in the world (in the log)
/term adopt ... / /term release ...   the same
```

Hold **Alt** (`CONFIG.adopt.pull_modifier`) over a flat window: a glowing
"pull into world" grip shows above its top edge (drawn on ImGui's foreground
list). Click it and the window flies out of its flat place into the world:
the full-screen flight run backwards, from the window's own rectangle. Any
top-level plugin window gets a grip (not ghostty's own, not popups or
click-through overlays); over the game's chat, the chat log gets one.

## Mappy is automatic

`CONFIG.adopt.auto = { mappy = true }` (lua/adopt.lua; a list such as
`{ 'mappy', 'chat2' }` works too): a listed window becomes a world panel
whenever it is open, with no command. When its plugin closes it the pet
goes quietly, and it comes back when it opens again. "Back to UI" by hand
leaves it flat until its window has closed and opened again. Settings →
"Flat windows in the world" → "Mappy's map is a world panel whenever it is
open" turns it off; the grip and `/window adopt mappy` still work.
Automatic windows are not in the saved list (they come back by themselves).

Mappy's id was checked against the installed Mappy 3.2.0.0 (the string
`###MappyMapWindow` in Mappy.dll); ChatTwo's against ChatTwo 1.40.6.0
(`Chat 2###chat2`). ImGui hashes only what follows `###`, so the id matches
whatever title the plugin shows.

## Frame ordering: the finding

Dalamud raises each plugin's `UiBuilder.Draw` in turn, all between one
`ImGui::NewFrame()` and one `ImGui::Render()`. The order is the order the
plugins subscribed, which no plugin controls: when ghostty's draw runs, the
adopted window may or may not have been drawn yet this frame. Copying its
draw list from ghostty's draw would show either this frame or a half-reset
one, and emptying it there would not stop a later draw from filling it again.

Two **ImGui context hooks** (`igAddContextHook`, imgui_internal, exported by
Dalamud's cimgui.dll; checked in the installed 15.0.3.5 and dev builds) take
the work out of that order:

* **RenderPre** runs inside `ImGui::Render()`, after `EndFrame` and every
  plugin's Draw, before any draw list is gathered for the renderer. There the
  adopted window's lists are complete. `core/app/adopt.nelua` copies the
  window's list, its child windows' (in ImGui's order) and its popups'
  (windows whose `RootWindowPopupTree` is the window; tooltips too while the
  pointer is inside it) into a snapshot, then empties them
  (`CmdBuffer.Size = 0`: `AddDrawListToDrawData` skips a list with no
  commands), so the window never reaches the screen. The window also gets
  `ImGuiWindowFlags_NoMouseInputs` for the next frame's hover test, so clicks
  pass through the invisible window to the game; its next `Begin` resets its
  flags anyway, so the bit only lives from Render to the next Begin.
* The snapshot is drawn **on the next frame**, inside the panel's content
  area (worldview calls `panel_content` where a terminal would be drawn), so
  it is bent with the rest of the panel by `world_transform_vertices`, sits
  between the panel's depth-test callbacks and fades with it. It is one frame
  (about 16 ms) late. Each triangle is clipped on the CPU against its
  command's clip rectangle (scissor rectangles mean nothing once vertices are
  projected) and cut into strips so a curved panel bends it; each command's
  texture is pushed with `ImDrawList_PushTextureID`.
* **NewFramePre** runs at the start of `ImGui::NewFrame()`, after Dalamud's
  backend queued the frame's mouse events. While the pointer is on the
  focused pet over the window (decided while drawing the pet), every queued
  mouse position in `g.InputEventsQueue` is rewritten to the matching point
  inside the real window (or one is queued), so ImGui hovers, clicks,
  scrolls, drags and types into the real window: Mappy's drag and zoom,
  ChatTwo's input line. When the remap ends the real position is put back.
  While a remap is on, ghostty's own code keeps seeing the real pointer:
  `imgui.GetMousePos`, `imgui.IsWindowHovered(AnyWindow)` (answered from the
  real pointer and the windows under it, adopted ones excluded) and
  `imgui.SetWindowFocusNil` (a no-op, so the click that lands on the pet does
  not take the window's text field focus) are wrapped in the function table.

Rejected: a draw-list callback (it runs in the renderer, after the vertex
buffers are uploaded: too late to add vertices), reading `GetDrawData` (no
hook between `Render()` and Dalamud's `RenderDrawData`), and hiding the
window with `HiddenFramesForRenderOnly` (a hidden window is never hovered, so
the pointer could not reach it).

The hooks go on with the first adopted window and off with the last, and in
`gu_shutdown`, `/term reload` and the kill switch. `igRemoveContextHook` only
marks a hook; ImGui never calls a marked one, so a core swapped by the loader
leaves nothing callable behind.

## Keeping the window valid

The window keeps being drawn by its plugin at its real screen place, and
ImGui culls what lies outside the display, so a window sticking out of the
screen (when it is adopted, or after its fit grew it) is moved inside it
(`igSetWindowPos_WindowPtr`) and moved back on release. Release also gives
back the plugin's own `NoMouseInputs` bit and its own size.

## The window fills the pet (`CONFIG.adopt.fit`, on by default)

* The pet takes the window's **inner area** once, when it is first drawn
  (`ImGuiWindow.InnerRect`: inside the title bar, menu bar and scrollbars) at
  `CONFIG.adopt.scale`. From then on the pet is the authority: every frame
  its content box, whatever resized it (the grips, a policy, the Lua anchor's
  width and height), gives the window size whose inner area has the box's
  shape (`adopt_window_for_panel`), and `igSetWindowSize_WindowPtr` asks for
  it when it changes (not every frame), and only while the window's `Size`
  and `SizeFull` agree: a size asked for last frame only reaches `Size` at
  the plugin's next `Begin`, and measuring the chrome between the two
  layouts would make the window creep. The plugin sees the new size on its
  next `Begin` and lays itself out to it, so Mappy re-fits its map.
* The pet shows the inner area **covering** its whole box (`adopt_cover`:
  the larger of the two scales, centred, cut by the box), so the title bar,
  the borders and any sliver from rounding fall outside the box. The window's
  flags are not touched (its next `Begin` would reset them anyway): the title
  bar is cropped, not removed.
* Too large for the screen at the scale: the window is asked for a smaller
  size at a larger scale and scaled up on the pet, and kept on screen.
* **Mappy crops to its map** (`crop = true` in `CONFIG.adopt.windows.mappy`):
  the pet covers its box with the bounds of what the window draws with
  textures other than its frame's (the font atlas), clipped to the inner
  area, when that is at least 30 % of it. A zoomed-out map with margins
  around it therefore still fills the pet; the pointer maps through the same
  crop.
* `CONFIG.adopt.fit = false` gives the old behaviour: the pet takes the
  window's size and shows all of it, contained.

## Beneath the flat UI and the game's HUD

* **Other plugins' ImGui windows**: an adopted window's snapshot is drawn
  inside its panel into the background draw list (step 9 in
  ARCHITECTURE.md), like every world panel, and that list is moved in front
  of whatever others drew there first (`world_under_ui_begin/end`); every
  ImGui window, flat HUDs of other plugins included, draws after it. Nothing
  of an adopted window goes to the foreground list (only the Alt grip does).
* **The game's own HUD** (`CONFIG.world.under_hud`, on by default; Settings
  → World → "Panels go beneath the game's HUD"): ImGui draws after the game's
  UI, so there is nothing to sort against. The shim's `hud_rects` returns the
  rectangle and name of each shown addon (`AtkStage` →
  `RaptureAtkUnitManager.AllLoadedUnitsList`, `IsVisible`, at most 64); the
  core drops those named in `CONFIG.world.under_hud_ignore` (name plates,
  fades, screen texts: layers over the whole screen) and any covering 60 %
  of the screen, and after each panel is projected cuts its triangles on the
  CPU against the rest (`core/hudmask.nelua`): triangles apart are kept,
  covered ones dropped, crossing ones replaced by their pieces outside the
  rectangles (new vertices, uvs and colours interpolated). All panels are
  cut (terminals, remote windows, adopted windows), not while flown full
  screen. A pointer over a HUD rectangle is not sent into an adopted window.
  A stencil was rejected: Dalamud's ImGui backend owns the render state
  between draw commands, and the HUD is axis-aligned boxes.
* An addon's rectangle is its root size (`ScaledWidth` x `ScaledHeight`),
  which for some addons is larger than what they draw: the panel is cut a
  little more than the visible element. A shim without `hud_rects` leaves
  panels uncut.

## The game's chat

The ChatLog addon is native UI and cannot be copied, so the chat pet draws
the chat itself (`core/app/chatpanel.nelua`, pure parts in
`core/chatlog.nelua`):

* The shim subscribes `IChatGui.ChatMessageUnhandled` (the lines the chat log
  shows) and forwards each as `gu_chat(type, sender, text)`: plain UTF-8
  (`TextValue`), from the framework thread. The core queues them under its
  lock; the frame moves them into a ring of the last 500 lines, kept whether
  or not the chat is pulled, so a pull shows the recent history.
* Lines are word-wrapped to the panel (breaks after spaces, long words cut
  between characters), newest at the bottom; the wheel and Page Up/Down
  scroll. Channel colours come from the game's own log colours
  (`UiConfig` `ColorSay`, `ColorParty`, ..., read through the shim and taken
  as 0xAARRGGBB, which is not verified), else from the palette in
  lua/adopt.lua.
* The input line: characters typed on the focused pet, Enter sends,
  Backspace, Esc clears (twice gives the keyboard back to the game). A line
  goes through `chat_send`: the shim sanitises it as the chat box would and
  refuses it if that changes it, then calls
  `UIModule.ProcessChatBoxEntry` on the framework thread, as xiv-mcp's
  `ChatInput.Submit` does. `/p`, `/tell` and other chat commands work as
  typed into the chat box; plain text goes to the game's active channel.
* While pulled, the addons in `CONFIG.adopt.chat.addons` (ChatLog,
  ChatLogPanel_0..3) that are shown are hidden (`AtkUnitBase.IsVisible`),
  again every 0.25 s if the game shows them; on release only the ones hidden
  this way are shown again.

## Shim forwarders (appended to GuHostApi; an older shim leaves them null)

| Field | What |
|---|---|
| `addon_rect(name, x, y, w, h)` | an addon's position and scaled size (`IGameGui.GetAddonByName`): 1 shown, 2 hidden, 0 not loaded |
| `addon_show(name, shown)` | `AtkUnitBase.IsVisible` |
| `chat_send(text)` | a line through the game's chat box (framework thread) |
| `config_uint(name, out)` | a `UiConfig` option (`IGameConfig`) |
| `hud_rects(out, cap)` | the shown addons' rectangles and names (`GuHudRect`), for cutting panels under the HUD; appended after `game_string` |

`gu_chat` is a new core export (the loader forwards it; the shim looks it up
with `TryGetExport` and subscribes only when it exists). With an older shim
the chat pet still opens but cannot hide the flat chat, send, or read
colours, and says so once in the log.

## Remembered across reloads

`/window adopt` and the grip record what is pulled in `adopted.lua` in the
config directory (not automatic ones). After `/term reload` or a restart,
once a character is loaded, each saved name is pulled again as soon as its
window is open (looked for for 30 seconds). `CONFIG.adopt.restore = false`
turns this off.

## Known risks (what to watch in game)

* **Internals.** `ImGuiWindow`, `ImGuiContext` and the input event queue are
  imgui_internal and change between Dear ImGui versions. The layouts come
  from the vendored cimgui.h at Dalamud's pinned commit; a Dalamud that ships
  another ImGui needs a rebuild against its header, or adopting will read
  garbage. Without `igAddContextHook`/`igFindWindowByName` adopting is
  refused with a log line; nothing else is affected.
* **One frame late.** The pet shows the previous frame's drawing. A texture
  the plugin frees between frames (an image shown once) could be drawn once
  after it is gone.
* **Docking and multi-viewport.** A window docked into another, or dragged
  out into its own OS window with Dalamud's multi-monitor option, has not been
  thought through; adopt it undocked, inside the game window.
* **Clicks on the pet also act on the panel**: the first click focuses it
  (as for remote windows), and a click may present the panel and turn the
  camera toward it like a click on a terminal. Double clicks inside the
  window never go full screen.
* **Keyboard.** While the pointer is not on the pet the window is
  click-through but keeps keyboard focus if it had it (a ChatTwo input line
  keeps typing until you click the world).
* **Chat hiding.** The game may show ChatLog again on its own (the chat box
  opened with Enter, UI resets); it is re-hidden within 0.25 s. Pressing
  Enter while the flat chat is hidden may activate its invisible input.
* **Chat colours** assume `0xAARRGGBB` in UiConfig; if they look wrong,
  set `CONFIG.adopt.chat.use_game_colours = false`.
* **Mappy.** Its map is textured quads larger than the window, clipped on
  the CPU every frame; a very large map window costs more CPU than a text
  window.

## Pieces

| File | Role |
|---|---|
| `core/hudmask.nelua` | pure: which HUD rectangles count, cutting them out of a projected panel |
| `core/adopt.nelua` | pure: window ↔ panel mapping, cover fitting, the window size for a pet, CPU clipping and strips, the draw-list copy, snapshots, pointer remap and the mouse event rewrite, keeping on screen, flags, the adopt/lose/give-up state machine, the grip's geometry, window names |
| `core/imgui_internal.nelua` | the imgui_internal declarations and optional exports, bound on first use |
| `core/chatlog.nelua` | pure: the chat ring, wrapping, the input line, game colours |
| `core/app/panelkit.nelua` | the fly-out, the title strip with "back to UI", calls into `CONFIG.adopt` |
| `core/app/adopt.nelua` | adopted ImGui windows: hooks, snapshots, pointer, release |
| `core/app/chatpanel.nelua` | the chat pet |
| `core/app/panels.nelua` | worldview's `panel_content`, commands, the grip gesture, automatic windows, restoring |
| `lua/adopt.lua` | known windows, automatic ones, sizes, the modifier, chat addons and colours, the saved list |
