# Architecture

```
 FFXIV process (Windows / Wine)                     Linux/macOS host, or Windows
 ┌───────────────────────────────────────────┐      ┌────────────────────────┐
 │ Dalamud ── GhosttyDalamud.dll (C#)        │      │ ghostty-agent (Nelua)  │
 │   │ Draw / OpenMainUi / commands / DTR    │      │  poll() / event wait    │
 │   ▼ ghostty_loader.dll (swaps the core)   │ TCP  │  forkpty or ConPTY      │
 │ ghostty_core.dll (Nelua)  ◄───────────────┼──────┤  256 KiB replay ring    │
 │  app/hostsurface activation, events, IPC  │      │  token handshake        │
 │  session.nelua   terminal ⇄ transport     │      └────────────────────────┘
 │  render.nelua    cells → ImDrawList       │
 │  input.nelua     ImGui keys → key encoder │      ConPTY (Windows only)
 │  policy.nelua    embedded Lua 5.4 VM      │ ◄──► pwsh / cmd / ssh.exe
 │  ghostty.nelua   libghostty-vt bindings   │
 │  imgui.nelua     cimgui.dll via GetProc   │
 │  lua/init.lua    profiles, keys, layout   │
 │   ▲ IPC GhosttyDalamud.v1.*               │
 │ Umbra ── Umbra.Ghostty.dll (C#, optional) │
 │           toolbar widget + popup node     │
 └───────────────────────────────────────────┘
```

## Why this shape

* **Dalamud only loads .NET assemblies.** `GhosttyDalamud.dll` is an ordinary
  plugin kept to forwarding: it loads `ghostty_core.dll` from beside itself,
  calls `gu_init_ex` with the install and config directories, forwards
  `UiBuilder.Draw` to `gu_frame` and the /xlplugins buttons, chat commands and
  info bar clicks to `gu_event`, and fills `GuHostApi` with callbacks (log,
  fonts, key state, camera, objects, animation, lights, shadow boards, desk props,
  commands, info bar, UI-hide flags, IPC, opening a link in the browser, a line in the chat). The core
  decides what to register, when, and under which names (`core/app/hostsurface.nelua`,
  `CONFIG.host` in lua/init.lua).
* **Umbra is optional.** `Umbra.Ghostty.dll` keeps its file, assembly name and
  widget id but holds no native code: the widget label and popup call
  `GhosttyDalamud.v1.Status / PopupSize / PopupDraw / PopupReset / Post` over
  IPC and show "ghostty offline" when the plugin is absent. While the widget
  polls, the info bar entry hides itself (`host.dtr.mode = 'auto'`).
* **Other plugins** open and move remote-window panels through
  `GhosttyDalamud.v1.Call` (JSON in, JSON out; [IPC.md](IPC.md)). Calls come
  on the caller's thread: reads answer from a snapshot the frame publishes,
  changes are queued for the next frame (`core/app/ipc.nelua`, `lua/ipc.lua`).
* **One core per process.** Activation goes INACTIVE → PENDING → ACTIVE ⇄
  SUSPENDED: init is refused (and retried every 2 s) while the legacy
  Umbra-hosted `ghostty_umbra.dll` is mapped or another core holds the
  per-process mutex; an active core suspends its UI if the legacy one appears.
* **Two homes.** The shipped `lua/` sits read-only beside the plugin; settings,
  world state and the user's `lua/` overrides live in the config directory,
  which comes first on `package.path`. `lua/migrate.lua` copies the old
  Umbra-hosted home over once (marker `migrated-from-umbra.txt`): copies are
  owner-only (mode 0600, or a user-only DACL on Windows), changed copies of
  shipped modules are parked in `legacy-lua/`, and `ghostty_umbra.dll` is
  renamed to `ghostty_umbra.dll.migrated`.
* **ImGui is called from Nelua, not C#.** Dalamud ships `cimgui.dll`
  (Dear ImGui 1.88 docking, `ig*` exports). The core resolves the ~60 exports
  it needs with `GetProcAddress` at runtime (`core/imgui.nelua`), so the shims
  never touch ImGui and tests can substitute a fake table. Types and enum
  values come from the vendored `cimgui.h` at Dalamud's pinned commit; the C
  compiler owns every struct layout.
* **libghostty-vt** is built with Zig for both the host (tests) and
  `x86_64-windows-gnu`, and linked statically into `ghostty_core.dll`.
  Bindings are `nodecl` records + imported enum names, never hardcoded values;
  `tests/test_ghostty.nelua` asserts sized-struct sizes against
  `ghostty_type_json()`.
* **Transports stream raw bytes.** The terminal never knows where bytes come
  from: `Session` owns a `TermView` (terminal + render state) and a transport.
  The agent protocol (`core/protocol.nelua`) is a 5-byte framed stream
  multiplexing many sessions on one socket. Terminal replies (DA, DSR, kitty
  responses) flow back through libghostty's `WRITE_PTY` callback into the same
  transport.
* **One agent, two platforms.** `agent/agent.nelua` holds the protocol,
  sessions, replay ring and detach marks once; the platform code sits beside
  it. POSIX: `pty_posix.nelua` (forkpty, non-blocking master) and
  `sys_posix.nelua` (wl-copy / xclip, `/dev/urandom`, token under
  `~/.config`), driven by `poll()`. Windows: `pty_windows.nelua` gives each
  session a pseudo console fed through two named pipes whose agent ends are
  overlapped (anonymous pipes cannot be), with its OVERLAPPED records and
  buffers in a heap block that never moves; `winloop.nelua` waits on one
  event per socket (`WSAEventSelect`), each shell's process handle and its
  pending pipe reads and writes with `WaitForMultipleObjects`, so an idle
  agent sleeps (at most 64 handles per wait; beyond that, and during the
  150 ms after a shell exits while the console may still hand over output,
  it polls every 50 ms). `sys_windows.nelua` has the Win32 clipboard (on a
  thread given one second, so a stuck clipboard never stalls the shells),
  `BCryptGenRandom` and the token under `%APPDATA%` with an owner-only DACL
  (`core/sys/fsbase.nelua`, shared with the core). Children get null standard
  handles with `STARTF_USESTDHANDLES`, as Windows Terminal does, so they talk
  to their pseudo console and not to the agent's own stdio.
  `agent/logic.nelua` holds the pure parts both builds use.
* **Platform defaults are Lua.** `ghostty.platform()` (`core/sys/platform.nelua`)
  says `'windows'`, or `'wine'` when ntdll exports `wine_get_version`;
  `lua/platform.lua` turns that into the agent's token file and the
  profiles. An agent profile's `fallback` names a conpty profile: while the
  last connection attempt failed (`host.agent_down`), new terminals open the
  fallback (`policy_open_profile`) and terminals still waiting for their
  shell switch to it (`Session:use_fallback`).
* **Lua decides, Nelua executes.** `policy.nelua` embeds Lua 5.4, loads
  `lua/init.lua`, and exposes typed config records; `keymap.lua`'s `on_key`
  is consulted for every named key press before the terminal sees it.
* **Themes are data.** `lua/themes.lua` reads Ghostty theme files from the
  shipped and the user's `themes/` and resolves `CONFIG.theme` into colour
  numbers; `core/theme.nelua` holds the result (spaceghost's values until
  one is read). Each terminal applies it to libghostty-vt's default colours
  and palette when its generation changes (`TermView:sync_theme`); the
  renderer takes selection and cursor-text colours from it; the chrome draws
  through `chrome_col`. Tooltips (`core/tooltip.nelua`) wait for a hover
  delay, draw in the theme and take their texts from `lua/tooltips.lua`.
* **No GC.** The core is compiled with `-P nogc` because it runs inside a
  foreign process on the render thread; allocations are explicit and short
  lived (`stringbuilder`/`vector` with `destroy`).

## Frame flow

1. Dalamud's `UiBuilder.Draw` calls `gu_frame` on the render thread.
2. Retry a pending activation or suspend/resume (every 2 s); drain queued
   events (chat commands, info bar clicks), retry commands another plugin
   held, push the info bar entry when it changed.
3. Bind cimgui exports once; pump the agent socket (non-blocking) and any
   ConPTY pipes (`PeekNamedPipe`), feeding bytes into each session's terminal.
4. Poll the toggle key (unless another ImGui text field wants input); swallow
   it from the game via `IKeyState`. Poll the controller toggle: a Dalamud
   gamepad flag through the shim or, with `toggle_gamepad_button = 'create'`,
   the DualSense's own HID reports (`core/sys/hid.nelua`: setupapi and
   hid.dll; `core/dualsense.nelua` parses them). Reads never wait: an
   overlapped `ReadFile` collected with `GetOverlappedResult`, on a handle
   whose report queue is cut to 2. Finding and opening the controller is
   synchronous, and closing waits up to 1 s for the cancelled read, so
   searches skip devices by the ids in their path, back off from 3 s to 30 s,
   and start early on a `CM_Register_Notification` device arrival. Create
   counts only while the game's window is in front. Not yet observed with a
   controller in game.
5. Draw the drop-down: an ImGui window sliding from the top of the main
   viewport; tab bar of sessions; `InvisibleButton` over the terminal area for
   focus; if focused, `SetNextFrameWantCaptureKeyboard(true)` and
   `input_poll` translates ImGui named keys + the character queue into
   libghostty key events, encoded by the key encoder (kitty/legacy aware).
6. `render_termview` walks the render-state rows/cells: merged background
   runs, one `AddText` per glyph cell, underline/strike lines, cursor.
7. World panels, pets, the character animation and world pins only once a
   character is loaded.
8. The popup terminal is drawn from our own anchored window (info bar
   right-click), or on demand from the Umbra popup node's `OnDraw` through
   IPC. The info bar's left click lists every terminal in another anchored
   window (`core/app/inventory.nelua`); a row brings its terminal forward.
9. World panels (`core/app/worldview.nelua`) are drawn in panel pixels into
   the background draw list and every vertex is mapped onto the panel through
   the game's view-projection matrix (`core/world.nelua`). Beneath the
   game's own HUD (`CONFIG.world.under_hud`, `core/hudmask.nelua`): once a
   panel is projected, its triangles are cut on the CPU against the screen
   rectangles of the shown game addons (`GuHostApi.hud_rects`), so the
   hotbars, chat log and minimap show through. Not yet observed in game.
10. Flat windows pulled into the world ([ADOPT.md](ADOPT.md)): two ImGui
   context hooks outside the plugins' draw order. RenderPre moves an adopted
   window's finished draw lists into a snapshot and empties them; the pet
   draws the snapshot the next frame in step 9. NewFramePre rewrites the
   queued mouse position into the window while the pointer is on its focused
   pet. The game's chat is drawn by the core from lines the shim forwards
   (`gu_chat`). The window takes the pet's shape (`CONFIG.adopt.fit`):
   `SetWindowSize` to the pet's box at `CONFIG.adopt.scale`, and the pet
   shows its inner area covering the box. Not yet observed in game.
11. Remote windows (docs/REMOTE_WINDOWS.md): WFRAMEs read in step 3 are
   decoded into each stream's CPU copy (`core/app/remotewin.nelua`) and
   acknowledged; `remotewin_tick` ends streams whose connection went and
   closes ended panels; a window panel's content, where a terminal would be
   drawn in step 9, uploads the dirty rectangles to its D3D11 texture on
   Dalamud's device (`core/wintex.nelua`), draws it as textured quads and
   sends the focused panel's pointer and keys back as WINPUT. Not yet
   observed in game.
12. Jobs (docs/JOBS.md): a process the agent runs on pipes rather than a PTY,
   for output a client parses instead of draws — a Claude Code session in
   `stream-json` mode above all. The agent passes its bytes through
   untouched; the events are rendered by XivDesktop, not by the plugin core.

## HUD panels

A world panel whose anchor is `hud` (lua/world.lua; `/term pin hud [X Y]
[DIST]`, or let a panel carried with Alt go within `CONFIG.world.hud.edge`
pixels of a side of the screen, or with Ctrl) is docked to a spot on the
screen but drawn as any other panel, in 3D, `M.hud.distance` yalms in front
of the camera and parallel to the screen. Its pixel density follows the
camera's field of view and the distance, so it keeps the screen size it was
docked at (`scale`, screen pixels per panel pixel); the anchor stores the spot
in screen fractions, so a new resolution keeps it. Each frame Lua reads the
camera frame (`ghostty.view`, from `world_view` in `core/world.nelua`) and
its turn rate since the last frame; springs (`M.hud`: stiffness, damping,
tilt, roll, drag, bob, max_tilt, max_drag) slide the panel back against the
turn, keep it facing where the camera looked and bank it (`roll`, a new
placement field the panel basis honours), then settle it on its spot. Every
spring value is clamped, so a fast spin cannot fling it; the camera moving
along its view (zoom) does not move it. HUD placements carry `hud = true`:
no depth test or character cut-out (always in front), no present, no camera
turn on a click, no shadow board, and no world tint or cast light. Not yet
observed in game.

## Resizing world panels

Any world panel (terminal, remote or adopted window, pet, pin or HUD panel)
resizes from all four edges and the corners (`core/app/resize.nelua`, driven
from `core/app/worldview.nelua`). The grip band is sized in screen pixels
(`world_grip`: 14 thick, 6 of them past the edge, corners reaching 28 along
both edges; inside the panel at most a quarter of its size), converted
through the panel's projection at that edge, so it stays usable at any
distance; the title-button row keeps its clicks. A press on a grip resizes
at once and focuses the panel; Alt + press is still the move gesture. While
a grip is hovered or dragged, that edge or corner glows (drawn in panel
pixels, so it bends with the curve) and the mouse is claimed
(`SetNextFrameWantCaptureMouse`), so neither the camera nor the character
reacts; a small size label (columns x rows for terminals, else panel pixels)
follows the cursor. The gesture ends on release wherever it happens.

Each frame the size is recomputed from the cursor's panel pixel on the panel
as drawn (ray against the panel's surface, extrapolated past its edge), so
the grabbed edge tracks the cursor 1:1 and any drift corrects itself.
`CONFIG.world.resize(id, w, h, keep, su, sv, right, up)` in lua/world.lua
clamps the size and, for pins and HUD panels, moves the anchor's centre by
half the growth along the panel's right/up vectors (a HUD panel in its screen
fractions, its scale unchanged), so the opposite edge stays fixed. Pets and
other anchors placed by their own logic grow about their centre at twice the
edge's movement. Window panels keep their window's aspect unless Shift is
held; terminals resize freely and their grid follows. A focused panel's
presentation is held still while it is resized. Not yet observed in game.

The game keeps its own cursor over ghostty (`core/app/cursor.nelua`): at the
end of `gu_frame`, while the pointer is over one of our ImGui windows (the
hovered window's popup-tree root has `ghostty` in its id: dropdown, popup,
settings, window picker, gallery prompt) or a hovered world, HUD or adopted
panel, `ImGuiConfigFlags_NoMouseCursorChange` is set for the next frame so
Dalamud's backend does not swap in an OS cursor; elsewhere it is cleared
again, only if we set it. Not yet observed in game.

## Pets: keeping out of the way, and how they move

**Status: host tests only (`tests/test_motion.lua`, `tests/test_world.nelua`,
`tests/test_worldpanel.nelua`). Not yet observed in game.** Nothing below has
been seen in FFXIV; in particular the game's collision has only been stood in
for by boxes in a fake `ghostty.raycast`.

Pets are placed by `M.place_pet` in lua/world.lua, with the maths in
lua/motion.lua (pure, no game). Every rule moves the point a pet's springs aim
at first, so it glides to a free place; what still gets too close is then a
*contact*: the pet is put back outside, loses the speed it had into the
obstacle (keeping `collide.bounce` of it) and squashes, instead of being
snapped back every frame.

* **Other panels.** A panel is its footprint on the ground plane: the chord of
  its (curved) face, from edge to edge. Two panels whose heights overlap keep
  `CONFIG.world.pet.collide.gap` between their nearest edges
  (`motion.panel_push`: exact along the nearest points when apart, the least
  push along the line between centres, found by halving, when they cross).
  Pets keep off the pets placed before them this frame and off every other
  world panel placed in the last quarter second (pins, `me`/`target`
  followers, orbits, windows); HUD-docked panels are not in the world and are
  left alone. Pins never move for a pet. A pet that runs into a panel on its
  way to a slot on the far side hops over it (a quick spring lifting its
  bottom just over the other's top, down again once it has been clear for a
  moment) rather than resting against it for good. Stacked pets now also sit
  `pet.stack_depth` further out per step back round you: two panels a step
  apart on the same circle cross each other, one behind the other do not.
* **You, and other characters.** A pet keeps out of your personal space
  (half its width + 0.6 about your centre, and `collide.body` from your
  middle) at once. `ghostty.nearby_characters()` lists the rest (the shim walks
  Dalamud's IObjectTable for players, battle NPCs, event NPCs and companions
  within 15 yalms at most ten times a second, with hitbox radius, model height
  and kind; nil in an older shim, where your target stands in as an NPC):
  - *mobs, NPCs and chocobos* are kept clear of at once, where they are and
    where they are going (their velocity, smoothed, `collide.predict`
    seconds ahead), their radius plus `collide.body`;
  - *other players* are let pass: a pet makes room only for one who stays in
    its place `collide.dwell` seconds, and goes back once they have been gone
    `collide.dwell_out`.
  Room is made the tidiest way: a character short enough to pass under
  (`collide.under` yalms, and a ray up from the pet's top for a ceiling) gets
  a *hike*: the pet tucks its hem up (the placement's `tuck`: the bottom edge
  drawn toward the top, the top edge where it was, not area-kept, at most
  `collide.tuck` of its height; none with Reduce motion) and floats up for the
  rest, then lets its hem down 0.35 s after it is no longer needed. Taller
  ones are stepped aside from. A pet held still to be read makes no room, and
  keeps a hike under way as it is.
* **The world: open space, not collision solving.** (Rebuilt after the
  in-game try of a5f1bf7, where pets "jumped around waaaay too much": 12 s of
  walking logged 50 frames of blinking and the chosen place flicking between
  -1.2 and +1.2 rad.) `ghostty.raycast` is the shim's `raycast_mode`, through
  `BGCollisionModule.RaycastMaterialFilter` with every collision layer and any
  material; ClientStructs' helper (layer 1, material bit 0x4000, what
  ScreenToWorld wants) missed props on other layers, and the wider filter hits
  grass too, so what counts is decided here, by size:
  * *The open map* (`open_tick`): a ring of rays from where you stand,
    `collide.open_dirs` (36) directions at three heights (0.6, 1.3 and 2.0
    yalms), out to `open_reach` (7), swept `open_rays` (24) rays a frame and
    again every `open_every` (0.4 s). A hit counts only if it is *tall* (the
    same direction hits at another height within 0.6 yalm) and *wide or close*
    (a neighbouring direction hits too, or it is within 4 yalms, where a post
    can fall between two directions): grass, kerbs, knee-high stones and thin
    stalks do not count (`motion.classify_ring`). Each direction's open
    distance is smoothed: closing quickly (0.15 s), opening slowly (0.9 s).
  * *Where a pet goes* (`place_open`): its slot while that has room
    (`motion.clearance`: every ring direction its face spans open past its face
    plus `margin`); else the open place nearest its slot, up to `swing` round
    you, outside the no-go cones and away from where another pet has moved;
    nowhere open, the roomiest, brought in as far as your personal space
    allows. Decided every 0.5 s (0.8 s while you move) with hysteresis: a place
    is left only after `bad_for` (0.3 s) without room, and it goes back to its
    slot only after staying `stay` (1.5 s). It drifts there over `drift` (0.9 s)
    through the animation layer; nothing jumps. A place the pet found blocked
    itself (something too thin for the ring, a pillar between its rays) counts
    as having no room for two or three seconds.
  * *Never seen inside anything large* (end of `M.place_pet`). Each time a
    pet moves `recheck` (3 cm) its face is looked at along three rows (near the
    bottom, the middle, near the top; `motion.face_rows`) and its way at two
    heights (`motion.path_rows`). The middle and top count when a ray each way
    hits, or one does and a second ray a little higher agrees (one stray answer
    is not a wall); the bottom row alone is clutter under it (grass tips, a
    crate, a short post): it floats over it if it can and never stops for it.
    Something large and it holds where it was clear, tries to squeeze through or
    float over (`find_way`), and after three blocked looks lets the open map
    choose again. It blinks only after `blink_after` (5) blocked looks and
    `stuck` (1 s), and never more than once every `blink_every` (4 s): a
    smootherstep shrink over `blink` (0.2 s; with Reduce motion a fade), a jump
    while hidden to the place the open map chose, once that is itself clear,
    and the same back in. At rest its face is looked at four times a second;
    something large there three looks running hides it at once. The first
    frame also looks from your chest (a face buried in a thick wall has nothing
    to hit along it). A pet with no rays left this frame holds still.
  All pets together cast at most `collide.rays` (96) rays a frame.
  `/term world rays [SECONDS]` logs per pet and frame the rays and hits (and
  those only the wide filter makes) and the place decided; `/term world anim
  [SECONDS]` the animations still moving. The `world` selftest reports a ring
  of 16 rays at knee height with each filter. None of this has been seen in
  game yet.
* **The view.** The existing no-go cones stay as they were: no pet centre
  between the camera and you, or straight behind you. A wide pet's edge may
  still reach into the camera cone; the cones were not widened, because the
  stacked slots would then fight the cones.

How they move (`CONFIG.world.pet.cute`, `pet.follow`, `CONFIG.world.motion`):

* One spring integrator for everything (`motion.step`): semi-implicit, in
  substeps of at most 1/120 s and short enough that `h * w <= 0.5`, a frame
  taken as at most 0.1 s. It never gains energy, whatever the stiffness or the
  frame rate, and 30, 60, 144 fps and a ragged frame rate trace the same curve.
* One animation layer (`motion.anim`, `motion.tween`): everything a pet
  shows besides the follow spring (its drift to a new place, the pull in, the
  floor and ceiling lift, a float over something, a hop, the tuck and the hike,
  squeezing, the row's size, its tilt, being held still, a blink) is either a
  critically damped glide that reaches its goal in a stated time with no
  overshoot, capped at a stated speed, with a dead zone so noise in the goal
  never makes it twitch; or a smootherstep tween that starts and stops with no
  speed. Each property has exactly one; properties that add up (the follow
  spring's height, the bob, a hike) are separate and each smooth. The panels'
  own glitch in and out (every world panel, Mappy's pet too) is eased with
  smoothstep instead of a linear ramp. `tests/test_motion.lua` samples each
  curve at 30, 60 and 144 fps: no speed jump bigger than the curve's own start,
  no overshoot past 2 %, settled in its time, still at rest.
* Calm by default (the first in-game try found them "way too flubbery"): the
  follow springs are near-critically damped (`pet.damping` 0.95; a step is
  followed without overshooting by more than 2 %, `tests/test_motion.lua`), the
  roll spring and the HUD springs are damped the same way.
* The bob is two sines at an irrational ratio, each pet at its own slow pace
  (0.85 to 1.15 of `cute.bob_speed`, 0.6 rad/s, from its phase), at most
  `pet.bob` (2 cm) up and down, so no two bob in step. An idle sway, a small
  tilt of its own (`cute.tilt`), a fan per step back for stacked pets
  (`cute.fan`, and the row beside a focused pet starts every other tier half a
  brick along instead of in columns), a little extra height per step back
  (`cute.nestle`), and a slight bank into sideways movement (`cute.lean`) are
  summed into the placement's `roll` through a spring of their own and never
  go past `cute.max_tilt` (2 degrees).
* Held still to be read: a pet you are typing into (keyboard focus) or
  pointing at (the core passes the panel under the pointer last frame as
  `held` to `CONFIG.world.place`) eases in a few frames to no bob, no tilt
  and no squash, so its text never moves while you read it.
* Squash: a spring of its own (`m_sq`), kicked only by real events (a
  contact, at most every quarter second; a fall that stops; popping back
  after a squeeze or a blink), never by stops or turns, and never past 4 %
  (`SQUASH_MAX`). The placement carries it as `squash`; `world_basis` makes
  the panel wider by 1 + squash and shorter by the same factor, and
  everything that works from the basis (projection, hit tests, the depth test)
  follows.
* A procession: each pet is `follow.stagger` (0.04) softer on its spring
  than the one before it in the order, so they set off and stop one after
  another.
* `CONFIG.world.motion.reduce` (Settings, Pets: Reduce motion) is a true
  zero: no bob, sway, tilt, fan, lean, squash or procession, and the springs
  settle without overshoot. Collision, squeezing and blinking stay, since they
  are what keeps a pet out of walls.

State kept on an anchor for this starts with `m_` and is never saved.

## World panels behind game geometry

ImGui draws after the game, so a world panel would cover everything. With
`CONFIG.world.occlusion = 'depth'` (the default) each panel is depth-tested
per pixel against the game's own depth buffer (`core/depthpass.nelua`):

* The shim forwards `RenderTargetManager.DepthStencil`'s shader resource view,
  its rendered/allocated size and Dalamud's `UiBuilder.DeviceHandle`
  (`get_scene_depth`, borrowed pointers).
* Around each panel the core adds draw-list callbacks: before the panel's
  first command one binds `core/shaders/panel_depth.hlsl` (precompiled DXBC,
  embedded as a Nelua byte array), the depth view at `t1`, a comparison
  sampler at `s1` and the panel's constants at `b0`; after it one unbinds
  them, then Dalamud's reset
  sentinel (`-8`, not ImGui's `-1`, which is Dalamud's blur) restores the
  renderer's state.
* ImGui vertices are 2D, so the shader recomputes the panel's depth per pixel:
  the pixel's camera ray against the panel's plane or cylinder slice, compared
  with the scene depth. The depth convention is read off the camera
  (`world_depth_mapping`): every perspective projection writes
  `ndc z = a + b / view depth`, so `view depth = b / (ndc z - a)` — reversed Z
  with an infinite far plane is `a = 0, b = near`, a finite far plane gives a
  non-zero `a`, and a standard forward projection a negative `b`, where the
  comparison sampler runs `LESS_EQUAL` instead of `GREATER_EQUAL`. The ray is
  unprojected through the view-projection with its depth column normalised to
  `(0, 0, 0, 1)` (`world_depth_vp`), which makes one step along the ray one
  yalm of view depth whatever the convention. The mapping the game really
  uses is logged once per session, to be confirmed in game.
  Four comparison taps around each pixel, each carrying the panel's depth
  along its screen slope, antialias covered edges over about a pixel
  (`CONFIG.world.occlusion_edge`) and average a dithered fade instead of
  showing its pattern. The tolerance grows with distance and with the panel's
  depth slope, so a panel lying on a wall does not shimmer. Degenerate cases
  draw the panel unchanged. `world_panel_ray_depth` mirrors the ray maths for
  the host tests.
* When any piece is missing (old shim, no depth view, unexpected format, a
  different device, a camera whose depth is no distance at all
  (orthographic, or a skewed depth column), shader creation failing, or
  callbacks that never run) the frame uses the older screen-space character
  capsule instead, and the reason is logged once. Callbacks that run but
  bind nothing count as not run. `/term depth` reports the state;
  `/term depth retry` forgets a latched failure; `/term depth show` colours
  panels by the test (red where the scene is in front, green where the panel
  is, blue where a pixel has no ray), to check edge alignment by eye.

The shader is rebuilt with `vendor/nelua-lang/nelua-lua tools/build-shaders.lua`
(vkd3d-compiler 1.17 in a disposable Fedora 44 container); normal builds use the
committed `.dxbc`. `tests/probe_depthpass.nelua` (manual, Wine + DXVK) draws a
curved panel with that bytecode over D24S8 depth written with known scenes and
checks every pixel: flat scenes against a model built on `world_panel_ray_depth`,
plus a surface flush with the panel (also one pixel out of line), a dithered
character, a silhouette edge and the show mode. Not yet observed in the game: whether the depth buffer
still holds the frame's depth when ImGui draws, the texel mapping under dynamic
resolution or upscalers, edge alignment during fast camera turns,
behaviour in gpose and cutscenes, and which depth convention the game's
camera matrix actually carries (the log line above answers that one).

## Panel shadows (experimental)

Off by default (`CONFIG.world.shadows.enabled`, "Screens cast shadows
(experimental)" in Settings → Light). ImGui panels are not in the scene, so
they cannot cast shadows by themselves. `core/app/occluders.nelua` gives each
shown world panel a client-side `BgObject`: a flat model
(`CONFIG.world.shadows.model`) scaled to the panel, turned by its yaw and
pitch, and set `offset` yalms behind it, so the game's own shadow pass sees
something where the panel is. The board follows the pose the panel is drawn
at, so it moves with a carried panel and with a focused one floating out to
meet you. The object exists only on this client and has
no collision.

* The shim forwards five callbacks (`bg_create`, `bg_ready`,
  `bg_set_transform`, `bg_set_transparency`, `bg_destroy`, appended to
  `GuHostApi`). `BgObject.Create` is found once with `ISigScanner`
  (FFXIVClientStructs' signature); when the scan fails `bg_create` stays null
  and the core leaves the feature off, as it does with an older shim.
* A board is created lazily, polled until its model has loaded
  (`ResourceHandle.LoadState == 7`), and only then transformed
  (`UpdateTransforms(false)`, `UpdateCulling`); the transform is sent again
  only when the pose changes. A model that has not loaded after 600 frames is
  freed with one warning.
* Boards are freed (`CleanupRender`, then `Dtor(1)`) when their panel is
  closed, hidden, asleep, derezzed or full screen, when the option goes off or
  the model changes, on a zone change, whenever no character is loaded, and in
  `teardown_effects` (shutdown, `/term reload`, the kill switch), so a loader
  swap leaves none behind.

None of this has been observed in game: whether the board's shadow looks
right, what `transparency` does to it, whether the model's size and origin
are as assumed, and whether creating objects from the draw callback is safe.
A game patch that changes `BgObject` can crash the game while the option is
on.

## Rain on world panels

When it rains in the world, drops land on the world panels' glass and a wiper
behind the glass sweeps them off. The split follows the visual bell:
`core/rain.nelua` is the simulation (no ImGui), `core/app/rain.nelua` draws
it, and `lua/rain.lua` decides whether it rains and holds the tunables.

* **Weather.** `CONFIG.rain.frame()` runs once per frame. It maps the game's
  weather id (`ghostty.env()`, which reads `EnvManager.ActiveWeather` and
  `EnvState.Rain`) through `M.weather` (Rain, Showers, Thunder,
  Thunderstorms) to an intensity from 0 to 1. The game's own rain amount is
  used when it is higher. Weather 0 counts as no weather, meaning indoors, so
  it is dry. `/term rain on|off|auto` forces rain on or off, or follows the
  weather again. `CONFIG.rain.panel(id)` keeps HUD-anchored panels dry.
* **Shelter.** The weather says whether it rains; whether rain reaches a
  panel is asked per panel, of the game's collision, not of where the player
  stands. While it rains, `rain_panel_shelter` casts three rays straight up
  (60 yalms) from the panel's top edge — left corner, centre, right corner, a
  hand's width in front of the glass — through the host's `raycast`. Open sky
  over a sample means rain lands on that part; a roof or overhang means it
  does not. The answers live in the panel's `RainShelter`: cast again every
  0.25 s, sooner (at most every 0.08 s) once the panel has moved 0.25 yalms,
  never more than 12 rays a frame for all panels together, and none at all in
  dry weather. Each sample eases over a second. The panel's intensity is the
  weather's times the exposed share of its width, and new drops land across
  the width in proportion to the blended samples, so a panel half under an
  overhang is wet on its open half only. A sheltered panel's target is 0: its
  drops evaporate over `fade` seconds and nothing is shed or flung. A housing
  interior (`indoor`, `HousingManager.IndoorTerritory`) and the territories
  in `CONFIG.rain.indoor_zones` are dry whatever the rays say. `/term rain on`
  and `CONFIG.rain.shelter = false` rain on every panel. Older shims without
  `raycast` behave as before. Not yet observed in game.
* **Drops.** Each panel has a fixed `RainPanel` holding up to 120 drops and a
  seeded xorshift generator, so the same seed and steps always give the same
  rain. The panel's level fades toward the intensity over `fade` seconds, and
  the drop count follows `max_drops × level`. New drops land with a splash
  ring. Drops grow and merge with the drops they touch. Drops past the
  trickle size run down with a wobble and a fading trail. They are drawn in
  front of the content as triangle fans (a translucent body with a darker
  rim, plus a specular dot toward the top left) in one reserved batch per
  pass, from a fixed vertex buffer.
* **Shaking it off.** There was no shake-off before this; it is driven by the
  panel's own motion and by nothing else. `rain_panel_shake` hands the pose
  about to be drawn (after `CONFIG.world.place`, the drag pose, the presented
  pose and the flight pose) to the panel's `RainMotion`, which takes velocity
  and acceleration as finite differences, low-passed over 0.05 s, plus a
  `spin` term for yaw, roll and curve changes at the panel's edge. So every
  way a panel moves is covered by construction. From `shake_slide` the drops
  slide against the in-plane acceleration (outward for spin) and streak; past
  `shake_accel` they come off at `shake_per` of the drops per yalm/s of
  velocity change beyond it, at most `shake_max` a step, as world droplets
  with the velocity the glass had 0.15 s earlier at that point — a hard stop
  sheds forward, a sudden start leaves the water behind, a spin sheds along
  the tangent. They use the run-off's falling path and ground ray (32 ground
  rays a frame, then the panel's last ground). A move of more than
  `shake_jump` yalms in a frame, faster than `shake_max_speed`, a turn of
  more than 1.5 rad in a frame, a quarter second without frames, or a HUD
  dock starts the history over without shedding. Resizing alone sheds
  nothing. Not yet observed in game.
* **Wiper.** An arm pivots from the middle of the bottom edge and rests along
  it. While it rains, it makes one eased sweep out and back every
  `wiper_period_light` to `wiper_period_heavy` seconds. From
  `wiper_continuous_at`, it sweeps without resting. Drops the blade crosses
  become short smears that fade. With `wiper_style = 'back'` (the default),
  the arm and blade are drawn as a dark silhouette after the panel's
  background and before the content. `'front'` draws them on the glass, and
  `'none'` leaves the wiper out.
* **Falling off the glass.** A drop that runs off a panel's bottom or side
  edge before the wiper reaches it, and the water the blade has collected,
  leave the panel as emits. Collected water is flung off the blade tip at each
  turn of the sweep, along the direction of travel. `rain_panel_shed` turns
  each emit into a world droplet: `world_point` on the panel basis gives the
  position, run-off keeps its trickle speed, and flung water leaves at
  `fling_speed`, a little off the glass. Droplets live in one fixed
  `RainPool` of 256 (`max_particles` caps it lower). They fall under
  `gravity` to the ground under their start point, found with one downward
  `raycast` (the player's feet when that misses), and then show a small
  splash ring. Flung droplets fade as they fly. `draw_rain_world` draws them
  just before `draw_world`, as projected streaks on the background list, so
  panels cover them. They are not depth-tested against the scene. Nothing is
  shed from HUD panels, indoors, or during the full-screen flight.
* `worldview` calls `rain_panel_back` after the background grid and
  `rain_panel_front` before `bell_panel_border`. Both run in panel pixels, so
  `world_transform_vertices` bends the geometry and applies the panel's light
  tint. The strips are cut into segments so they follow the curve. Only
  visible, awake panels reach these calls. A panel unseen for 30 s loses its
  state.

Tested on the host only (tests/test_rain.nelua). None of this has been
observed in game yet: the weather ids and the weather-0-means-indoors rule
are assumptions, and how the drops and wiper look on a panel is unverified.
## Desk scene

Opt-in (`CONFIG.animation.style = 'desk'`, "Style" in Settings → Character
animation; the phone stays the default). Opening a terminal, the same trigger
as the phone pose, puts a desk and a chair where the character stands and
sits it down to work. `lua/desk.lua` decides what and where;
`core/app/deskprops.nelua` makes the furniture, using the same client-side
`BgObject` callbacks and rules as the panel shadows above.

* Lua asks with `ghostty.desk_props({...})` (model, position, yaw, uniform
  scale per prop; `core/desk.nelua`) and `ghostty.desk_props(nil)` to let go.
  The chair goes at the character's feet facing its way, the desk in front
  turned toward it. Models are the Origenics Monitor Desk and Origenics Chair
  (HousingFurniture model keys 1419 and 1420, both paths checked against the
  game's sqpack index), swappable in `CONFIG.animation.desk.models`.
* Scale: `desk.scale = 'normal'` is the furniture's own size (made for an
  average adult Midlander), so a smaller character looks like a child at a
  grown-up desk; `'fit'` scales by the character's model height over
  `reference_height`; a number is a factor. The chair defaults to `'fit'`,
  so the seated pose meets its seat.
* Props are created lazily, polled until loaded, transformed once (again
  only when Lua moves them), and freed when the terminal closes, when the
  character walks off, and whenever `desk_block` is set: a cutscene, group
  pose, a loading screen or an event (a new `scene_flags` callback appended
  to `GuHostApi`; an older shim reports none of these), combat, a mount, a
  zone change or no character. They are also freed on the no-world path of
  the frame loop and in `teardown_effects`. A blocked scene does not come
  back by itself; the next terminal toggle starts a new one.
* The pose is the local character's base override, as with the phone
  (`AnimSet` with the mode untouched, `AnimPlay`): nothing goes to the
  server. It holds a seated `event_base_chair_*` loop and changes mood every
  8–25 s by a weighted, seedable draw (`desk.moods`: working 9287, writing
  4203, reading 5593, thinking 9001/5511, stretching 5752, yawning
  1068/9040, frustrated 9042 with additive 664, sipping 9033/9190). A
  character that is already seated, mounted or in combat gets the phone.
* **Seated phone.** Over a sit (`Character.Mode` InPositionLoop 11, whose
  ModeParam is the EmoteMode row: 1 ground, 2 chair, 3 bed; or EmoteLoop 3)
  the pose's seated variant plays instead of its standing loop, picked per
  sit kind from the Emote sheet's ActionTimeline[2] (ground), [3] (chair)
  and [4] (upper body, for the rest): /tomestone is 6303 for all three,
  /read 7359 on the ground and 7358 on a chair. It plays once per sit kind
  and loops on its own; not yet confirmed in game.

Not yet observed in game: the furniture's origin, facing and depth, whether
the seated loops' seat height meets a fitted chair, what
`GameObject.Height` holds for `'fit'`, and whether creating objects from the
draw callback is safe (the shadow boards carry the same risk).

## Character reactions

`CONFIG.animation.reactions` (on by default). `core/app/reactions.nelua`
compares each terminal's counters once a frame and calls
`CONFIG.animation.on_event(kind, time, a, b)` while the pose is out:
`bell`, `done` (exit status, seconds since the command started) and
`output` (bytes). Exit statuses come from OSC 133;D, which libghostty-vt does
not surface, so `core/cmdwatch.nelua` scans the output for 133;C and 133;D
itself (a byte-at-a-time state machine, nothing buffered, replayed output
skipped); a shell without integration reports only its own non-zero exit.
`lua/animation.lua` turns events into short additive or facial timelines
(`reaction_table`: weights, cooldowns, durations) that play over the hold,
standing, seated or at the desk, and replays the hold when one ends: a bell
looks up, a failed command shakes the head or curses, a success after
10 s nods, output after a quiet spell while you are not typing earns a
glance, and 30–90 s without typing a fidget. Not yet observed in game.

## Repository layout

```
core/         Nelua plugin core (compiled to ghostty_core.dll)
core/app/     the app modules; hostsurface.nelua is the plugin's side of the host
core/sys/     net (POSIX + Winsock), conpty (Windows), procguard, fs / fsbase, platform, wincmdline, hid and dualsense_reader (Windows HID)
core/shaders/ HLSL sources and the committed DXBC the core embeds
agent/        ghostty-agent PTY server (Nelua): agent.nelua, logic, pty_posix / sys_posix, pty_windows / sys_windows / winloop
agent/        raw jobs (docs/JOBS.md): jobs.nelua, job_posix / job_windows, claude.nelua (the Claude Code command line)
lua/          shipped policy: init.lua, keymap.lua, migrate.lua, assistant.lua (/term ask), selftest.lua (/term selftest), ...
themes/       shipped colour themes (Ghostty theme files, read by lua/themes.lua)
shim/         GhosttyDalamud (plugin) and Umbra.Ghostty (widget) C# projects
tests/        host tests + run.sh
tools/        fetch-vendor.sh, build.sh, package.sh, install-dev.sh, zig-cc*.sh, build-shaders.lua, crash-restart.{nelua,sh} (Linux/Wine only)
              build-container.sh / build-remote.sh: the Incus build container and the builds that run in it (docs/BUILDING.md)
vendor/       pinned third-party checkouts (git-ignored, see toolchain.env)
```

## Where a build runs

Heavy builds do not run on the gaming PC: it has 15 GB of RAM and the game in
it, and `tools/build.sh` gets killed for low memory. The default is an Incus
container on a separate build host, driven by `tools/build-container.sh` and
`tools/build-remote.sh`, with `build/dist/` copied back here to install and
test in the game. The whole arrangement, the shared compiler cache and what
stays local are in
[BUILDING.md](BUILDING.md).

## Pins

`toolchain.env` pins Nelua (the project's fork, `NELUA_REPOSITORY`), ghostty,
gc-cimgui (Dalamud's submodule commit), umbra-dist, Lua, Zig and .NET, and the
Wayland SDK: the Fedora 44 `-devel` RPMs of wlroots 0.20.2, wayland 1.26.0,
wayland-protocols 1.48, pixman 0.46.2, libxkbcommon 1.13.1 and libdrm, fetched
from Koji by NVR with their sha256 and unpacked (headers only) into
`vendor/wayland-sdk/include`. The agent links the host's own libraries against
them (`tools/wayland-flags.sh`); without them it builds without the Linux
window backend. Dalamud's ImGui uses 16-bit
`ImWchar` (verified against `Dalamud.Bindings.ImGui`'s generated `ImGuiIO`),
so `InputQueueCharacters` holds BMP code points.

## Contributing constraints and tests

* New code is Nelua or Lua. The C# shims (`shim/GhosttyDalamud`,
  `shim/Umbra.Ghostty`) stay logic-free forwarders.
* C and Zig only as vendored code; no new `.c` files.
* Pins live in `toolchain.env`, and `tools/fetch-vendor.sh` honours them.
* `tests/run.sh` runs on the host (Nelua + gcc, no game, no Windows) and must
  end with `ALL OK`. Suites, in `tests/`:

| Suite | Covers |
|---|---|
| `test_ghostty` | libghostty-vt binding: sized-struct sizes against `ghostty_type_json()` |
| `test_render` | a terminal rendered through a fake ImGui, checked by its draw calls |
| `test_glyphfb` | fallback glyphs (`core/glyphfb.nelua`, docs/GLYPHS.md): code points above U+FFFF (emoji included) and BMP glyphs the ImGui font lacks rasterized with stb_truetype from `fonts/` into a fake D3D11 atlas and drawn as tinted images at their cells (2D snapped, world unsnapped), wide glyphs over exactly two cells, the lazily read font chain and a font added behind it, the tofu box with hex digits for a code point no font has, `ImFont_FindGlyph` in place of `ImFont_FindGlyphNoFallback`, the cache, a full atlas starting over, device changes |
| `test_session` | session behaviour without a transport, local sessions, agent LIST parsing, `/term send` escapes, gamepad gestures, key repeat |
| `test_dualsense` | DualSense input reports (USB, Bluetooth with its CRC, Bluetooth simple, short and foreign reports), Create edges, ids in HID interface paths, the HID reader against fake devices: scan, devices passed over by their path, open, report queue, unplug, rescans backing off, device arrivals, close |
| `test_selection` | mouse selection: hit mapping, click counting, word and line units, copied text |
| `test_bell` | the visual bell: BEL counting, ring and glow maths, the Lua style, its triangles |
| `test_policy` | loading `lua/init.lua`: defaults, profiles, key actions, showcase entries |
| `test_world`, `test_worldpanel`, `test_worlddrag` | world panels: projection and hit testing, the presented pose and walk-up, drag placement and snapping, resize grips (screen-pixel size near and far, every edge and corner with the opposite edge fixed, pets, HUD panels, Alt still moving, release off the panel), the pet order (`order swap`) and the title drag that asks for it, the game-cursor flag over ghostty UI, all against a fake game |
| `test_remotewin` | remote window panels against a fake version 3 agent, a fake ImGui and a fake texture table: open, KEY and delta frames, dirty-box uploads, WACK (held while asleep), the textured quads over the letterboxed picture, pointer / button / wheel / key / text input with the chrome keeping its clicks, WEND, WCLOSE, an older shim, a version 2 agent refused; WGEOM popups past the panel's edge and their input, window keys saved and restored across `/term reload`, refused keys and reconnects, reserved chords, WLIST watch opening new windows and dialogs beside their panels, `CONFIG.windows.never`, late app icons, resizing keeping the window's aspect (Shift frees it) |
| `test_worldhud` | HUD panels: roll in the panel basis, the camera frame, the docked spot and size at rest (within a pixel), the lag and settling on a synthetic camera turn, clamps under a wild spin, zoom, the bob, docking maths, the dock hook and persistence in screen fractions |
| `test_remotewin` | remote window panels against a fake version 3 agent, a fake ImGui and a fake texture table: open, KEY and delta frames, dirty-box uploads, WACK (held while asleep), the textured quads over the letterboxed picture, pointer / button / wheel / key / text input with the chrome keeping its clicks, WEND, WCLOSE, an older shim, a version 2 agent refused |
| `test_adopt` (`.nelua` + `.lua`) | flat windows in the world, pure parts ([ADOPT.md](ADOPT.md)): window ↔ panel mapping, CPU clipping and strips, the draw-list copy through a fake ImGui, snapshots, cover fitting with no gap, the window size for a pet box, cropping to textured content, the pointer remap and mouse event rewrite, keeping a window on screen, flags, the adopt/lose/give-up state machine, the pull grip, window names, the chat ring, wrapping, the input line and colours; lua/adopt.lua's names, sizes, saved list and colours |
| `test_hudmask` | panels beneath the game's HUD: which addon rectangles count (ignored names, full-screen layers, the viewport offset), a triangle minus a rectangle, cutting a hand-built draw list (a band, a corner, apart, covered, a command shared with earlier drawing, callbacks and textures kept, interpolated uvs and colours, ImGui's write cursors) |
| `test_adopt_app` | the same in an embedded core against fake ImGui internals and a fake shim: hooks on and off, RenderPre snapshots emptying the window, click-through, moved on screen and back, the pet drawing it, the pointer remapped (queued events rewritten, the core still sees the real pointer), lost and regained, reload and restore, release, the chat pet (lines, addons hidden and shown, typing sent), the pull grip, Mappy adopted automatically (closed, reopened, given back, the settings switch), fitting (the window follows the pet's shape and resizes, asked once, kept on a screen too small for it, its size given back) and the HUD read from the shim (full-screen layers left out, the pointer not taken into the window over a HUD element) |
| `test_host` | the exported host surface without ImGui: init, status, commands, the controller toggle's source and its foreground check, shutdown |
| `test_lights` | panel lights against fake game light callbacks |
| `test_occluders` | panel shadow boards against fake background object callbacks: placement, lifecycle, an older `GuHostApi` |
| `test_chrome` | the glass chrome of the drop-down and windows: colour, tint, glow, tab strip, buttons, the settings button's badge |
| `test_themes` (`.nelua` + `.lua`) | themes: Ghostty theme files and the extension, user themes over shipped ones, spaceghost against the built-in colours, the shipped themes against upstream, switching at runtime (terminals, selection, cursor-text, chrome), the Theme combo, a tooltip for every setting |
| `test_migrate` (`.nelua` + `.lua`) | the one-time migration from the Umbra-hosted home |
| `test_hostsurface` | the plugin side against a recording fake host: activation and refusals, registration and shutdown order, suspension, events, info bar, `ghostty.open_url` (https only) and an older shim's smaller `GuHostApi` |
| `test_vote` (`.nelua` + `.lua`) | the feature vote link: the shipped catalogue, new-idea count, the settings window's section and badge, the seen marker through `settings.lua` |
| `test_platform` (`.nelua` + `.lua`) | `ghostty.platform()` on the host, `lua/platform.lua` per platform, the shipped `init.lua` as Windows and as Wine, the fallback choice and an agent terminal switching to its fallback |
| `test_assistant` (`.nelua` + `.lua`) | `/term ask`: the argv a question becomes (one element: quotes, `;`, unicode, empty), chat without one, pet / tab / window, the off switch, the terminal kept open with `[assistant exited]` and the not-found hint (127 and an agent refusal), the local ConPTY fallback |
| `test_selftest` | `/term selftest`'s pure parts: suite selection, the JSON report and summary, the state handed across a core swap, the fingerprint, a terminal read back through recorded draw calls, the render hash, the world round trip against a game-like camera |
| `test_selftest_run` | `/term selftest` in an embedded core: every suite in order (game-only ones skip), the Lua suites, the report files, a run carried on from a state file, stale and unreadable state, a run cut short by shutdown |
| `test_agent_logic` | the agent's pure parts: OPEN parsing, replay plans, ring indexes, CRLF for the Windows clipboard, env entries, default shells, the Windows wait timeout, command line quoting |
| `test_capture_win32` | the Win32 window capture backend's pure parts: USB HID → virtual key, key message lParams, the characters keys stand for, mouse and wheel words, SendInput absolute coordinates, blank (all-black) captures, UTF-8 → UTF-16 for WM_CHAR, WLISTR lines, window matching |
| `test_agent` | `ghostty-agent` end to end over TCP |
| `test_wincodec` | remote window frames: changed tiles, QOI both ways, banding, WFRAME write/parse/apply, malformed input, downscaling |
| `test_capture_mac` | the macOS capture backend's pure parts: HID to kVK keycodes, key flags, mouse event types and click counts, frame pixels to global points, the Block literal layout, `run:APP`, window picking and WLISTR lines, UTF-16 text chunks, CGImage layouts to BGRA (the backend itself has never run on a Mac) |
| `test_agent_windows` | remote windows end to end over TCP against `--windows test`: list, open by id and match, KEY and delta frames rebuilt, scaling, flow control, every input kind, close, WEND, failures, streams per connection, `--windows off` |
| `test_capture_wayland` | the Wayland backend's pure parts: USB HID to evdev, codepoint to key and Shift in real xkb keymaps (us, de), `run:` parsing, `app:`/`desktop:` forms and nested desktop commands, WLIST lines with launch ids, window keys and their scores, the render node choice and nvidia-smi parsing, matching (only with `vendor/wayland-sdk`) |
| `test_agent_browser` | links in the agent's compositor (`agent/browser.nelua`): URL checks, the browser's command line from an Exec or `--wayland-browser`, `--wayland-browser-profile` argv, matching a browser's windows and processes |
| `test_desktop_entries` | installed apps (`agent/desktop_entries.nelua`): .desktop parsing, Exec field codes, lookup by id and fuzzy name, `app`/`term` list lines, icon lookup in a made-up theme tree, icon cache jobs (PNG copied, SVG rendered by the host's rsvg-convert or ImageMagick) |
| `test_wayland_compositor` | the agent's Wayland compositor with a real client (`yad`, GTK3): launch through `run:`, map, frame size and content, click and TEXT/KEY/WHEEL input changing the pixels, WLIST, close, a launch that exits without a window; context menus outside the window (xdg and X11) with their boxes; an X11 client through Xwayland; release and re-attach by key; WLIST `apps` and `app:` launches with cached icons; a nested desktop (cage); text-input-v3 and the clipboard read back through `yad --entry`; writes PNGs to `build/test-scratch/wayland` (only with `vendor/wayland-sdk`; skipped without yad) |
| `test_e2e_wayland` | the plugin's agent client against a real `ghostty-agent --windows wayland`: `run:yad`, KEY and delta frames with WACK pacing, click and TEXT reaching the app, WGEOM for a context menu, the clipboard both ways (`--clipboard-file`), a disconnect keeping the app and WOPEN `key:` re-attaching it, a Flatpak GTK4 app staying mapped, SIGTERM ending the apps the agent launched (only with `vendor/wayland-sdk` and yad) |

The last step checks that the core also compiles as a native host module.

`tests/smoke_agent_windows.nelua` is manual: a host client for a running
`ghostty-agent.exe` (on Windows, or under Wine in a throwaway prefix) that
opens `cmd.exe`, types into it and checks replay, LIST, clipboard and exit
status, printing PASS / FAIL per step (see the README for what it showed).

Two more manual smokes cover the Win32 window capture backend (on Windows or
under Wine; docs/REMOTE_WINDOWS.md records what they showed):
`tests/smoke_capture_win32.nelua`, built as a Windows exe, drives the backend
directly against a window picked by name (list, frames, a picture as PPM,
click and typing, the Edit control read back); `tests/smoke_windows_win32.nelua`
is a host client for `ghostty-agent.exe --windows win32` (WLIST, WOPEN by
match, frames rebuilt into a PPM, input, WCLOSE).
