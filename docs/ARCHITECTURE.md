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
  fonts, key state, camera, objects, animation, lights, shadow boards,
  commands, info bar, UI-hide flags, IPC, opening a link in the browser). The core
  decides what to register, when, and under which names (`core/app/hostsurface.nelua`,
  `CONFIG.host` in lua/init.lua).
* **Umbra is optional.** `Umbra.Ghostty.dll` keeps its file, assembly name and
  widget id but holds no native code: the widget label and popup call
  `GhosttyDalamud.v1.Status / PopupSize / PopupDraw / PopupReset / Post` over
  IPC and show "ghostty offline" when the plugin is absent. While the widget
  polls, the info bar entry hides itself (`host.dtr.mode = 'auto'`).
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
8. The popup terminal is drawn from our own anchored window (info bar click),
   or on demand from the Umbra popup node's `OnDraw` through IPC.
9. World panels (`core/app/worldview.nelua`) are drawn in panel pixels into
   the background draw list and every vertex is mapped onto the panel through
   the game's view-projection matrix (`core/world.nelua`).
10. Remote windows (docs/REMOTE_WINDOWS.md): WFRAMEs read in step 3 are
   decoded into each stream's CPU copy (`core/app/remotewin.nelua`) and
   acknowledged; `remotewin_tick` ends streams whose connection went and
   closes ended panels; a window panel's content, where a terminal would be
   drawn in step 9, uploads the dirty rectangles to its D3D11 texture on
   Dalamud's device (`core/wintex.nelua`), draws it as textured quads and
   sends the focused panel's pointer and keys back as WINPUT. Not yet
   observed in game.

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
  with the scene depth (reversed Z, infinite far plane: view depth = near / z).
  Four comparison taps around each pixel, each carrying the panel's depth
  along its screen slope, antialias covered edges over about a pixel
  (`CONFIG.world.occlusion_edge`) and average a dithered fade instead of
  showing its pattern. The tolerance grows with distance and with the panel's
  depth slope, so a panel lying on a wall does not shimmer. Degenerate cases
  draw the panel unchanged. `world_panel_ray_depth` mirrors the ray maths for
  the host tests.
* When any piece is missing (old shim, no depth view, unexpected format, a
  different device, a non-reversed-Z camera, shader creation failing, or
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
resolution or upscalers, edge alignment during fast camera turns, and
behaviour in gpose and cutscenes.

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

## Repository layout

```
core/         Nelua plugin core (compiled to ghostty_core.dll)
core/app/     the app modules; hostsurface.nelua is the plugin's side of the host
core/sys/     net (POSIX + Winsock), conpty (Windows), procguard, fs / fsbase, platform, wincmdline, hid and dualsense_reader (Windows HID)
core/shaders/ HLSL sources and the committed DXBC the core embeds
agent/        ghostty-agent PTY server (Nelua): agent.nelua, logic, pty_posix / sys_posix, pty_windows / sys_windows / winloop
lua/          shipped policy: init.lua, keymap.lua, migrate.lua, assistant.lua (/term ask), ...
shim/         GhosttyDalamud (plugin) and Umbra.Ghostty (widget) C# projects
tests/        host tests + run.sh
tools/        fetch-vendor.sh, build.sh, package.sh, install-dev.sh, zig-cc-win.sh, build-shaders.lua, crash-restart.{nelua,sh} (Linux/Wine only)
vendor/       pinned third-party checkouts (git-ignored, see toolchain.env)
```

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
| `test_session` | session behaviour without a transport, local sessions, agent LIST parsing, `/term send` escapes, gamepad gestures, key repeat |
| `test_dualsense` | DualSense input reports (USB, Bluetooth with its CRC, Bluetooth simple, short and foreign reports), Create edges, ids in HID interface paths, the HID reader against fake devices: scan, devices passed over by their path, open, report queue, unplug, rescans backing off, device arrivals, close |
| `test_selection` | mouse selection: hit mapping, click counting, word and line units, copied text |
| `test_bell` | the visual bell: BEL counting, ring and glow maths, the Lua style, its triangles |
| `test_policy` | loading `lua/init.lua`: defaults, profiles, key actions, showcase entries |
| `test_world`, `test_worldpanel`, `test_worlddrag` | world panels: projection and hit testing, the presented pose and walk-up, drag placement and snapping, all against a fake game |
| `test_remotewin` | remote window panels against a fake version 3 agent, a fake ImGui and a fake texture table: open, KEY and delta frames, dirty-box uploads, WACK (held while asleep), the textured quads over the letterboxed picture, pointer / button / wheel / key / text input with the chrome keeping its clicks, WEND, WCLOSE, an older shim, a version 2 agent refused |
| `test_host` | the exported host surface without ImGui: init, status, commands, the controller toggle's source and its foreground check, shutdown |
| `test_lights` | panel lights against fake game light callbacks |
| `test_occluders` | panel shadow boards against fake background object callbacks: placement, lifecycle, an older `GuHostApi` |
| `test_chrome` | the glass chrome of the drop-down and windows: colour, tint, glow, tab strip, buttons, the settings button's badge |
| `test_migrate` (`.nelua` + `.lua`) | the one-time migration from the Umbra-hosted home |
| `test_hostsurface` | the plugin side against a recording fake host: activation and refusals, registration and shutdown order, suspension, events, info bar, `ghostty.open_url` (https only) and an older shim's smaller `GuHostApi` |
| `test_vote` (`.nelua` + `.lua`) | the feature vote link: the shipped catalogue, new-idea count, the settings window's section and badge, the seen marker through `settings.lua` |
| `test_platform` (`.nelua` + `.lua`) | `ghostty.platform()` on the host, `lua/platform.lua` per platform, the shipped `init.lua` as Windows and as Wine, the fallback choice and an agent terminal switching to its fallback |
| `test_assistant` (`.nelua` + `.lua`) | `/term ask`: the argv a question becomes (one element: quotes, `;`, unicode, empty), chat without one, pet / tab / window, the off switch, the terminal kept open with `[assistant exited]` and the not-found hint (127 and an agent refusal), the local ConPTY fallback |
| `test_agent_logic` | the agent's pure parts: OPEN parsing, replay plans, ring indexes, CRLF for the Windows clipboard, env entries, default shells, the Windows wait timeout, command line quoting |
| `test_capture_win32` | the Win32 window capture backend's pure parts: USB HID → virtual key, key message lParams, the characters keys stand for, mouse and wheel words, SendInput absolute coordinates, blank (all-black) captures, UTF-8 → UTF-16 for WM_CHAR, WLISTR lines, window matching |
| `test_agent` | `ghostty-agent` end to end over TCP |
| `test_wincodec` | remote window frames: changed tiles, QOI both ways, banding, WFRAME write/parse/apply, malformed input, downscaling |
| `test_capture_mac` | the macOS capture backend's pure parts: HID to kVK keycodes, key flags, mouse event types and click counts, frame pixels to global points, the Block literal layout, `run:APP`, window picking and WLISTR lines, UTF-16 text chunks, CGImage layouts to BGRA (the backend itself has never run on a Mac) |
| `test_agent_windows` | remote windows end to end over TCP against `--windows test`: list, open by id and match, KEY and delta frames rebuilt, scaling, flow control, every input kind, close, WEND, failures, streams per connection, `--windows off` |
| `test_capture_wayland` | the Wayland backend's pure parts: USB HID to evdev, codepoint to key and Shift in real xkb keymaps (us, de), `run:` parsing, WLIST lines, matching (only with `vendor/wayland-sdk`) |
| `test_wayland_compositor` | the agent's Wayland compositor with a real client (`yad`, GTK3): launch through `run:`, map, frame size and content, click and TEXT/KEY/WHEEL input changing the pixels, WLIST, close, a launch that exits without a window; writes `first.png` and `typed.png` to `build/test-scratch/wayland` (only with `vendor/wayland-sdk`; skipped without yad) |
| `test_e2e_wayland` | the plugin's agent client against a real `ghostty-agent --windows wayland`: `run:yad`, KEY and delta frames with WACK pacing, click and TEXT reaching the app, SIGTERM ending the apps the agent launched (only with `vendor/wayland-sdk` and yad) |

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
