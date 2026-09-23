# A terminal in a game window ("native")

**Status: first seen in game on 3fc98a6: `/term selftest native` passed 8/8,
and the window did not work** — an opaque black background where the ImGui
windows are translucent glass, and a click into the text did not keep the
keyboard. Both are fixed below and checked on the host; the fixes have not been
seen in game yet, and the self-test now measures both there (colour read back
from the screen, real clicks). Everything below was
designed against the installed Dalamud (commit `e81744f6`), FFXIVClientStructs
and KamiToolKit 2.2.48 (source commit `9c61d0f8`, the version XivDesktop ships),
read from their sources, and checked only against fakes
(`tests/test_nativewin.nelua`, `tests/test_native_app.nelua`). `/term selftest
native` exercises the real path in game; its report is the first evidence
this works. The list of what can still fail is at the end.

```
/term native            the active terminal (or a new one) as a game window
/term native new [N]    a new terminal from profile N as a game window
/term native off        the focused game window back to an ImGui window
/term native status     whether the native path is available, and why not
/term native debug      hover, press and focus changes in the log (on/off)
```

The tab bar and the floating window header have a "Show as a game window"
button beside Window / Pin / Pet.

## What the window is

A real game addon (an `AtkUnitBase` made with KamiToolKit's `NativeAddon`),
not an ImGui window dressed up as one:

* the game's own window frame, title bar, close button and drag; the title
  bar's context menu (scale, reset position) like every KamiToolKit window;
* the game's z-order: other game windows, their tooltips and context menus
  go over or under it the way they do over any window, because it *is* one;
* the game's UI scale (`AtkUnitBase` global scale, and the window's own scale
  from its context menu), the UI hiding with Scroll Lock, cutscenes and group
  pose, and Esc / close-all like any window that has no text field focused.

Its content is one image node. Its texture is the terminal, drawn every frame
by the same renderer the ImGui panel uses (`draw_terminal` → `render_termview`),
so colours, themes, the cursor and the fallback glyphs are the panel's. Behind
the text is the body of the ImGui windows' glass — the dropdown's palette at its
opacity, lit by the world — and the terminal's default background is left out
over it (`bg_alpha` 0), exactly as `draw_windows` does. The first build filled
the texture with the theme's background at full opacity; spaceghost's is
`#000000`, which is the black the owner saw.

The window's title is "Ghostty" and the terminal's own title is its subtitle,
cut with an ellipsis to what fits (`native_title_fit`): the title bar's font
drew the `~` of `jack@alienware:~` as a ligature.

## How the terminal gets into the image node

1. **An offscreen draw list.** The core builds its own `ImDrawList` with
   cimgui's constructor (`ImDrawList_ImDrawList(igGetDrawListSharedData())`,
   the exports `/term selftest render` already uses), resets it each frame,
   fills it with the theme background and draws the terminal into it in
   texture pixels with `draw_terminal`. Nothing renders that list on screen.
2. **Dalamud renders it into a texture.** `ITextureProvider.CreateDrawListTexture`
   gives an `IDrawListTextureWrap`: `Draw(ImDrawListPtr, pos, scale)` renders a
   draw list with Dalamud's own ImGui renderer into a D3D11 render target,
   saving and restoring the device context around it
   (`DrawListTextureWrap.Draw` → `Renderer.RenderDrawData`, then `MakeStraight`
   from premultiplied to straight alpha). It honours `VtxOffset`, so a large
   terminal past 65 535 vertices draws correctly with 16-bit indices; it skips
   draw callbacks (the terminal draws none).
3. **The game samples that texture.** KamiToolKit's `ImGuiImageNode.LoadTexture`
   calls `ITextureProvider.ConvertToKernelTexture(wrap, leaveWrapOpen: true)`,
   which makes a `Kernel::Texture` around the *same* `ID3D11Texture2D` and
   view (it `AddRef`s them; it does not copy — read in
   `TextureManager.FromExistingTexture.cs`). So each `Draw` is what the image
   node shows on the game's next UI pass.
4. **Resizing does not recreate the texture every time.** The wrap is kept at
   a capacity (rounded up to 256 px) and the image node's part shows only the
   used rectangle (`U`, `V`, `Width`, `Height` in texture pixels); only growing
   past the capacity makes a new wrap, which `LoadTexture` swaps in (it
   disposes the previous one).

### Crisp at any UI scale

With the addon at scale `S` (screen pixels per UI unit), the content rectangle
`cw × ch` in UI units covers `cw·S × ch·S` screen pixels. The texture is made
exactly that many pixels, the part is that rectangle, and the image node is
`tex / S` UI units, so one texel lands on one screen pixel. The node is placed
so its screen origin is a whole pixel (`round(ax + cx·S)`), otherwise bilinear
filtering would soften every glyph by half a pixel. The terminal is drawn at
`font_px = base · font_scale · S` pixels with a font built at that size
(`push_mono_font_px`, a small per-size cache in the shim, built by Dalamud's
font atlas in the background; until it is ready the 40 px world font is used,
minified). All of this is `native_layout` in `core/nativewin.nelua`, tested on
the host.

## Input

**Keyboard.** The same path as the ImGui panel: while the game window has
terminal focus, `draw_terminal` runs with `focused` true, calls
`SetNextFrameWantCaptureKeyboard(true)` (Dalamud then keeps the keys from the
game) and `input_poll` turns ImGui's key events and character queue (IME text
included) into libghostty key events. Keymap actions (paste, copy, zoom, the
toggles) work as in the panel. When the window loses focus nothing claims the
keyboard and every key goes to the game again. Esc goes to the program while
the terminal is focused (vim needs it); with focus elsewhere Esc is the
game's and closes the window like any other.

**Focus** (`native_focus_step`, pure and tested):

* a press on the window focuses it, and takes ImGui's window focus away so no
  ImGui terminal types too; opening it by command focuses it;
* a press anywhere else, the window closing or hiding, the UI hiding,
  movement or combat intent (`host.drop_focus`), or another terminal taking the
  keyboard drops it. "Another terminal" is an edge — a world panel becoming
  focused, the dropdown opening — never a flag that can stay set. The first
  build used `host.dropdown_focus_next`, which waits for the dropdown to draw;
  with the dropdown hidden it stayed set and took the keyboard back the frame
  after every click, which is the "input does not stay" the owner saw.
* "On the window" is the shim's hover, three ways: 1 the game finds our addon
  under the pointer, -1 another addon (in front of ours there: a click
  elsewhere), 0 none — which is also what it says while ImGui has the mouse,
  so then our own rectangle decides (`native_on_window`). Before, 0 counted as
  elsewhere, so the second click on a focused window (whose mouse we had
  taken) dropped the focus too.
* Esc goes to the program while the terminal has focus (vim needs it); it is
  not a way out. A click elsewhere, movement or `/term native off` is.

**Mouse.** Dalamud hands ImGui mouse buttons and the wheel only while ImGui
wants the mouse (`Win32InputHandler`: `WM_MOUSEWHEEL` and button messages are
queued for ImGui only under `WantCaptureMouse`; moves always reach both). So:
the first click on a window that does not have terminal focus goes to the
game, which brings the window forward and focuses it; the core sees that
press from the raw button state (`GetAsyncKeyState`, as for world panels) and
gives the terminal focus. From then on, while the terminal has focus and the
pointer is on its text, the core sets `SetNextFrameWantCaptureMouse`: clicks
and the wheel come to the terminal and the camera neither turns nor zooms.
The title bar and frame are never taken, so the game drags the window and
opens its menu itself. The core acts only while the game says our addon is
the one under the pointer (`AtkCollisionManager.IntersectingAddon`, read by
the shim), so a game window over ours keeps its own clicks. Inside the
content:

* left press, drag and release select as in the panel (`terminal_mouse`:
  words, lines, Shift extends, Ctrl+click opens links, copy on select);
* a program that tracks the mouse (modes 9, 1000, 1002, 1003; SGR 1006 or the
  legacy encoding) gets press, release and motion reports instead
  (`TermView:mouse_bytes`, tested); Shift forces selection, as in other
  terminals;
* the wheel scrolls the scrollback, or goes to the program as wheel reports or
  arrow keys, Ctrl+wheel zooms (`terminal_wheel`, as in the panel);
* the bottom-right corner is a resize grip; dragging it resizes the game
  window (`native_resize` → `NativeAddon.SetWindowSize`) and the grid reflows,
  exactly as when an ImGui window resizes (`s:resize` with the new columns and
  rows).

## Life cycle and persistence

`host.native` holds the terminals shown as game windows (a view like tabs,
windows, minimized and world). The layout file saves them as view `native`, so
they come back as game windows after a reload or restart; their size and
position are kept in `native-state.lua` in the config directory
(`lua/native.lua`), keyed by the agent's session id, and a new window takes
the last size used.

When the game closes the window (its ×, Esc, close-all) the terminal goes to
the minimized list, with its shell still running, like minimizing a tab. When
the window disappears because the UI was hidden (Scroll Lock, a cutscene,
group pose, a loading screen) it is put back when the UI returns
(`native_close_kind`). KamiToolKit closes rather than hides its addons, which
is why this distinction lives in the core.

## Fallback

`/term native` asks `native_state(0)` whether the native path is ready. If it
is not — an older shim without the callbacks, KamiToolKit failing to start,
cimgui without the draw list exports, the window failing to open within 5 s,
or three failed draws — the terminal goes to an ImGui floating window instead,
and the reason is said once in chat and kept for `/term native status`.
Nothing on this path may throw into the game: every shim callback catches and
returns 0, and KamiToolKit is touched only through a class that is loaded
inside a `try` (a missing `KamiToolKit.dll` is a caught load error, not a
crash). No ImGui window is begun on this path, so there is no push/pop to
balance; the font push and pop inside `draw_terminal` are unchanged.

## What was rejected, and why

* **An ImGui window laid over an empty native addon.** Identical rendering and
  the least code, but ImGui draws after the game: the terminal would cover
  game windows, tooltips and context menus meant to be over it, lag a frame
  behind a dragged window, and ignore the game's fade on close. Not a game
  window.
* **A D3D11 renderer of our own in Nelua** (shaders through
  `tools/build-shaders.lua`, state save and restore). Dalamud already ships a
  tested one for exactly this (`IDrawListTextureWrap`); a second one would add
  shader tooling and the risk of leaking device state into the game's frame.
* **Atk text nodes, one per row.** The game's fonts are not monospaced and lack
  box drawing, Nerd Font symbols and most emoji; per-cell colours would need
  hundreds of nodes; the terminal would not look like the panel.
* **CPU rasterising into a dynamic texture** (stb_truetype, as the fallback
  glyphs do). Every changed frame re-rasterised on the CPU and uploaded, with
  different anti-aliasing than the panel.
* **A native text input node for the keyboard.** It would give the game's IME
  caret, but a text input swallows the keys a terminal needs as keys (arrows,
  Ctrl combinations, function keys, Esc).
* **An `AtkUnitBase` without KamiToolKit.** Reimplementing its virtual table
  handling, ULD setup and window node is where the crashes would come from;
  KamiToolKit is already used in game by XivDesktop.

## What is unproven, and could still fail in game

Host tests cover the layout maths, the focus rules, the close rules, the mouse
reports and the core's frame loop against a fake shim. None of the following
has been observed:

1. **Thread and timing.** `gu_frame` runs in `UiBuilder.Draw`; `IDrawListTextureWrap.Draw`
   asserts the main thread there. If Dalamud's draw is not on the thread it
   calls "main", the draw throws (caught): the window stays blank, and after
   three failures the terminal falls back to an ImGui window.
2. **The texture reaching the node.** Whether `ConvertToKernelTexture` of a
   render target that is redrawn every frame shows the new content (it shares
   the resource, so it should), whether the game's UI renderer samples it
   with the part rectangle we set, and whether the game's high-resolution UI
   mode (`_hr1` textures) halves or doubles part coordinates for a kernel
   texture.
3. **Pixel crispness.** That one texel maps to one screen pixel depends on the
   image node drawing its part at node size × scale with no further scaling,
   and on the addon's screen position being what `AtkUnitBase.X/Y` report.
4. **Colours.** Dalamud's offscreen renderer premultiplies and straightens; the
   game's UI shader then blends it. With the default opaque background this
   should equal the panel; translucent backgrounds may differ slightly.
5. **Hover.** `AtkCollisionManager.IntersectingAddon` being our addon while the
   pointer is over the content (the content has no collision node of its own;
   the window's background collision is assumed to cover it).
6. **The mouse split with the game.** The first click on an unfocused window
   reaches the game (to raise and focus it); whether a drag started there turns
   the camera, and whether the wheel over an unfocused window zooms it, is
   the game's behaviour over any window and has not been checked. The wheel
   does not scroll a window until it has terminal focus (Dalamud only forwards
   the wheel while ImGui has the mouse). While the mouse is taken, the game
   still sees moves but not clicks, so `IntersectingAddon` stays current; that
   it does is assumed from Dalamud's handler, not observed.
7. **Close versus hide.** Whether the UI hiding (Scroll Lock, cutscenes) makes
   KamiToolKit close the addon (handled: it is put back) or merely hides it
   (handled: it is drawn again when visible), and whether `GameUiHidden` is
   already set when that close happens.
8. **Fonts per size.** Each new pixel size adds a font to the plugin's atlas and
   rebuilds it; Ctrl+wheel zoom walks through sizes. The cache keeps four.
9. **IME.** Text arrives through ImGui's character queue as in the panel, but
   the IME candidate window is placed by Dalamud, not at the terminal cursor.
10. **Controller.** No gamepad navigation into the window.

`/term selftest native` checks, in game: the shim's callbacks are present and
KamiToolKit started; a window opens for a self-test terminal and reports a
scale and content size; the layout gives a texture of exactly content × scale
pixels at a whole-pixel origin; five frames draw without an error; focus is
taken by the window on opening; **colour**: eight swatches (greys, spaceghost
red, green, blue) drawn through the game window and the same through ImGui's
foreground list, one frame read back from the back buffer (the `/term shot`
capture) and compared pixel by pixel, within 6 per channel, with the transfer
that would explain grey 128 and a `CONFIG.native.gamma` to try when they
differ; **click focus**: the cursor moved onto the text and the left button
pressed and released through the OS (`mouse_event`, so the game, Dalamud and
the core see it as a player's), twice, and the window must have the keyboard
for all 20 frames after each click (skipped when the game is not in front or
another game window covers the spot; the cursor goes back afterwards); the
window closes and the terminal is gone; and a forced failure falls back to an
ImGui window. The first version checked only that focus was taken on opening
and the texture's size, which is how it passed 8/8 on a window that did not
work.

`CONFIG.native.gamma` (lua/native.lua, 1 by default) encodes every vertex
colour for a game UI that decodes sRGB; the owner's screenshot suggests it is
not needed (spaceghost's red text read back as `#cd5454` against `#cc6666`,
the red channel exact, which a decode would have made 153), and the colour
case measures it.
