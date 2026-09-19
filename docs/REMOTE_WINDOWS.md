# Remote windows

Windows on a machine running `ghostty-agent` can be pulled into the game as
world panels: a pet, a pin, anything a terminal panel can be. On Windows and
macOS these are desktop windows the agent captures. On Linux the agent is a
headless Wayland compositor of its own and the game is its only display: apps
started into it become windows there and nowhere else (see "Linux: the agent
is the compositor"). Either way the agent sends only what changed and plays
the plugin's mouse and keys back into the window.

```
 FFXIV (plugin core)                               ghostty-agent (any desktop)
 ┌───────────────────────────────┐   TCP     ┌──────────────────────────────────┐
 │ core/app/remotewin.nelua      │  WOPEN →  │ agent/windows.nelua              │
 │  Session kind Window          │ ← WFRAME  │  streams, tile diff, flow control│
 │  core/wintex.nelua (D3D11)    │  WACK  →  │ agent/capture_*.nelua (backends) │
 │  core/wincodec.nelua (decode) │  WINPUT → │  wlroots (Linux) │ Win32 │ macOS │
 └───────────────────────────────┘           └──────────────────────────────────┘
```

Status: this is the required design. What has been observed working is
recorded under "Verified" at the end of this file; everything else is not.

## Protocol (version 3, additive)

Agents greet with `ghostty-agent 3 <nonce>`. Clients send window frames only
to version 3 agents. All integers are little endian. `sid` is a window stream
id (u32), its own number space, never a PTY session id.

client → agent

| type | name | payload |
|---|---|---|
| 11 | WLIST | – , or `apps` (installed apps instead of windows, below) |
| 12 | WOPEN | req u32, wid u32, max_w u16, max_h u16, fps u8, then optional UTF-8 match text |
| 13 | WACK | sid, seq u32 |
| 14 | WINPUT | sid, kind u8, body (below) |
| 15 | WCLOSE | sid |

agent → client

| type | name | payload |
|---|---|---|
| 24 | WLISTR | lines `wid\tw\th\tapp\ttitle\n`; a wid 0 line describes what WOPEN with wid 0 does. Readers keep further columns after the title (a newer agent's; `key:K` marks a stable window key) and lines `app\tid\tname\ticon\tcategories` (apps the agent can start). Linux adds a `launch` column (below) |
| 25 | WOPENED | req u32, sid, w u16, h u16, title UTF-8 (sid 0: failed, the text says why) |
| 26 | WFRAME | sid, seq u32, w u16, h u16, flags u8, nrect u16, rects… |
| 27 | WEND | sid, reason UTF-8 (window closed, capture refused, …) |
| 28 | WGEOM | sid, seq u32, n u16, n × (x u16, y u16, w u16, h u16) |

WOPENED answers WOPEN by its client-chosen `req`, and may come much later
(an app being launched has not shown its window yet) and out of order. `wid 0`
+ match text means "first window whose title or app contains the text,
case-insensitive", waiting for one to appear; on Linux `wid 0` + `run:CMD`
starts CMD in the agent's compositor and opens its first window.

WFRAME carries the window's current size `w`×`h` and a list of rectangles
that changed. Flags: bit 0 KEY (the rectangles cover the whole window; the
client drops what it had), bit 1 END (the last WFRAME of this `seq`: present
it). One `seq` may span several WFRAMEs so no payload exceeds
`PROTO_MAX_PAYLOAD`. A size change always comes as a KEY frame.

Each rectangle: `x u16, y u16, w u16, h u16, enc u8, len u32, bytes[len]`.

* enc 0 RAW: `w*h*4` bytes BGRA, rows top to bottom, no padding.
* enc 1 QOI: the rectangle's pixels as a QOI chunk stream (no header, no end
  marker), alpha ignored and always 255; decoded length is exactly `w*h`.

WGEOM (additive; agents send it only when the picture can be more than the
window, so far the Linux compositor): where things are in a stream's
picture, in pixels of the frames as sent (after scaling). Box 0 is the
window itself; the others are its popups (menus, tooltips, combo lists)
that reach outside it, so the picture is the rectangle around all of them.
It comes right before the first WFRAME of `seq` whenever the boxes change,
and holds from that seq's END on; the first one comes with the first frame.
A client that ignores it still maps input correctly (WINPUT coordinates
are picture pixels), but shows the picture shrinking while a menu is open
and black where neither window nor popup is.

What the plugin has to do with WGEOM (core/app/remotewin.nelua; not done):

1. Keep the latest boxes per stream, parsed as above, applied when the
   frame with that `seq` is presented.
2. Size and place the panel from box 0 only: the panel's aspect and
   letterbox come from the window's w×h, not the picture's, so opening a
   menu does not resize or shift the window on the panel.
3. Draw the texture's box-0 region into the panel as today (UVs = box 0 /
   picture size), then each other box as its own quad at the same scale,
   offset from the window's placement by (box − box 0), even where that is
   outside the panel (menus hang over the panel's edge in the world).
   Nothing outside the boxes is drawn (it is black in the picture).
4. Input: a panel point maps to picture pixel = box 0's origin + the point
   in window pixels; points over a popup quad outside the panel go to the
   stream too (map through that quad), so a menu below the panel can be
   clicked. A click outside every box still goes to the stream (it closes
   the menu).
5. Old agents never send WGEOM: treat "no boxes" as box 0 = the whole picture.

Flow control: the agent keeps at most 2 unacknowledged `seq` per stream. The
client sends WACK with the `seq` it presented. A stream nobody acknowledges
stops producing frames, which also bounds memory on both sides.

WINPUT kinds (coordinates are window pixels of the latest frame):

| kind | body |
|---|---|
| 1 MOVE | x i16, y i16 |
| 2 BUTTON | x i16, y i16, button u8 (0 left, 1 right, 2 middle), down u8 |
| 3 WHEEL | x i16, y i16, dx i16, dy i16 (1/120 notch units, +y = away from user) |
| 4 KEY | hid u16 (USB HID usage, page 7), down u8, mods u8 (1 ctrl, 2 shift, 4 alt, 8 super) |
| 5 TEXT | UTF-8 |
| 6 FOCUS | – (raise/focus the window where the backend can) |

KEY is used for named keys (arrows, enter, F-keys, shortcuts); TEXT for typed
characters, so layouts on the two ends need not match.

## Pieces

| File | Side | Role |
|---|---|---|
| `core/protocol.nelua` | both | frame constants above |
| `core/wincodec.nelua` | both | tile diff, rect packing, QOI encode/decode, WFRAME build/parse; pure, host-tested |
| `agent/windows.nelua` | agent | streams, WLIST/WOPEN/WACK/WINPUT/WCLOSE, flow control, calls a backend |
| `agent/capture.nelua` | agent | the backend interface and the `--windows` choice |
| `agent/capture_test.nelua` | agent | synthetic windows (moving pattern) for tests; `--windows test` |
| `agent/capture_wayland.nelua` | agent (Linux) | a headless wlroots 0.20 compositor in the agent: xdg toplevels are the windows, pixman renders them, wlr_seat takes the input; `run:` launches apps into it |
| `agent/wayland_keys.nelua` | agent (Linux) | USB HID to evdev, codepoint to key in the xkb keymap (for TEXT) |
| `agent/capture_win32.nelua` | agent (Windows) | EnumWindows, PrintWindow(PW_RENDERFULLCONTENT) with BitBlt fallbacks, window messages / SendInput; pure parts in `agent/capture_win32_logic.nelua` |
| `agent/capture_mac.nelua` | agent (macOS) | CGWindowList for the list, ScreenCaptureKit for frames, CGEventPostToPid |
| `core/wintex.nelua` | plugin | a BGRA D3D11 texture per stream, dirty-rect uploads, the SRV as ImTextureID |
| `core/app/remotewin.nelua` | plugin | Session kind Window: open/close, draw on a panel, pointer and keys back, `/term window` |
| `lua/windows.lua` | plugin | agents to ask, sizes, fps, which windows auto-pull |

## Backend interface (agent/capture.nelua)

A `CaptureBackend` record of function pointers (see the file for the exact
signatures): `list`, `open`, `state`, `title`, `frame`, `input`, `close`,
`pump`, `poll_fds`, `wait_ms`. `--windows NAME` picks one: `auto` (the
default) means the platform's own, `wayland` on Linux, `win32` on Windows,
`mac` on macOS; `off` means none; `test` is the synthetic backend. A platform
backend joins the build by flipping its entry in `CAPTURE_BUILT` at the end of
`agent/capture.nelua` to true, which requires its file and calls its
`capture_<name>_backend(): (boolean, CaptureBackend, string)`; until then
`capture_select` answers "<name> backend not built". An agent without a
backend keeps serving terminals, answers WLIST with ERR and WOPEN with a
failed WOPENED, both carrying the reason.

Frames are BGRA top-down (alpha ignored), at the window's own size; the
generic layer scales frames larger than `max_w`×`max_h` down
(`wincodec_downscale`), rate-limits to `fps`, diffs and encodes. An open may
stay pending (a launched app has not mapped its window yet); the WOPENED
goes out when it settles.

## The generic layer (agent/windows.nelua)

* A stream belongs to the connection that sent its WOPEN. WACK, WINPUT and
  WCLOSE naming another connection's `sid` are ignored, and a connection's
  streams are closed when it goes. A backend with `release` (the Linux
  compositor) then keeps the window and its app for a later WOPEN; the
  others close the stream as for WCLOSE.
* WOPENED goes out once `state` leaves PENDING. Live: `sid`, the size of the
  first frame as sent (after scaling; 0×0 when the backend has no frame yet)
  and the backend's title, followed by the KEY frame. Ended first, or an
  immediate `open` failure: `sid` 0 and the reason.
* `fps` 0 means 30; it is clamped to 1..60. A frame goes out only when its
  time is due, fewer than 2 `seq` are unacknowledged, the client's output
  queue is under 4 MiB, the backend's `serial` changed and some visible pixel
  changed. The agent keeps a copy of what the client shows and diffs against
  it; the first frame and every size change are KEY frames.
* Scaling is by the smallest integer factor that fits (box filter). WINPUT
  coordinates are pixels of the frames as sent; the agent maps them back
  (`x * factor + factor / 2`) and clamps them to the window.
* WCLOSE has no answer. A live stream whose `state` becomes ENDED gets WEND
  with the backend's reason and is forgotten.
* The main loop sleeps no longer than `wait_ms` of the backend and of the
  next due frame of a stream that may send; POSIX also polls the backend's
  `poll_fds`. The Windows loop has only the timeout.

## Windows backend (agent/capture_win32.nelua)

Plain Win32 and GDI, no WinRT or D3D. The agent makes itself per-monitor DPI
aware (`SetProcessDpiAwarenessContext(PER_MONITOR_AWARE_V2)`, looked up at
run time, absent before Windows 10 1703) so sizes and coordinates are
physical pixels.

* **List**: `EnumWindows`, keeping visible top-level windows that are not
  cloaked (`DWMWA_CLOAKED`: other virtual desktops, suspended UWP apps), have
  no owner (dialogs, popups), are not tool windows, and have a title and a
  non-empty client area. `app` is the exe base name
  (`QueryFullProcessImageNameW`; empty when the process cannot be opened,
  e.g. an elevated one), `title` is UTF-8 with tabs and newlines as spaces.
* **Window ids** are the HWND truncated to 32 bits. Windows keeps window
  handles 32-bit significant on 64-bit systems (32- and 64-bit processes
  share them); the id is sign-extended back. `open` checks `IsWindow`.
  `wid 0` + match picks the first listed window whose title or exe contains
  the text (ASCII case-insensitive); `wid 0` without a match is refused
  ("pick a window by id or name"): there is no system picker. Streams are
  live at once.
* **Frames**: on demand from `frame()`, at most one capture per 16 ms per
  window. The client area goes into a top-down 32bpp DIB section, reused
  until the size changes, through `PrintWindow(PW_CLIENTONLY |
  PW_RENDERFULLCONTENT)`, which on Windows 8.1+ also gets covered windows and
  DirectX / Chromium content. When that fails or leaves the (cleared) DIB all
  black, `BitBlt` from the window's DC, then from the screen at the client
  area (both only see what is visible). A copy of the last frame is kept;
  `serial` changes only when the pixels differ (`memcmp`), so an idle window
  costs nothing downstream. Minimised windows keep their last frame. The
  title is reread every 500 ms. A destroyed window ends the stream
  ("window closed").
* **Input without FOCUS**: window messages, sent with
  `SendMessageTimeout(SMTO_ABORTIFHUNG, 100 ms)` in order; the user's
  foreground window is never touched. Mouse events go to the deepest visible
  child under the point (`ChildWindowFromPointEx`, coordinates converted to
  that child's client space) as `WM_MOUSEMOVE` / `WM_[LRM]BUTTON*` with the
  `MK_*` state; the wheel as `WM_MOUSEWHEEL` / `WM_MOUSEHWHEEL` (screen
  coordinates, +120 = away from the user, the WINPUT sign). KEY becomes
  `WM_KEYDOWN`/`UP` (`WM_SYSKEY*` with alt) with a VK from the HID usage, the
  scan code from `MapVirtualKeyW` and the repeat/extended/transition bits;
  it goes to the window thread's focus window when that is inside the
  window, else the child last clicked. TEXT is one `WM_CHAR` per UTF-16 unit
  (a surrogate pair as two).
  Messages are sent rather than posted because `TranslateMessage` queues a
  posted key's `WM_CHAR` behind everything already posted: under Wine,
  "enter, then TEXT" came out as the text, then the newline. Sent messages
  are not translated, so the character a key stands for is sent too: enter,
  tab, backspace, escape and ctrl+letter (control codes); letters and other
  printable keys are expected as TEXT.
  Limits: no message changes the keyboard state apps read with
  `GetKeyState`, and sent messages skip the app's message loop, so menu
  accelerators, dialog navigation and many ctrl shortcuts do not work this
  way; FOCUS is the path for them.
* **FOCUS**: restores a minimised window and brings it to the foreground
  (`SetForegroundWindow` with the `AttachThreadInput` trick; Windows may
  still refuse and flash the taskbar button). From then on, while the window
  really is the foreground window, input goes through `SendInput`: absolute
  mouse moves over the virtual desktop (`MOUSEEVENTF_ABSOLUTE |
  MOUSEEVENTF_VIRTUALDESK` after `ClientToScreen`), buttons and wheel, keys
  with VK and scan code (modifiers named in `mods` but not held through
  their own KEY events are pressed around the key, so ctrl+c works), TEXT as
  `KEYEVENTF_UNICODE`. When the user switches away, input falls back to
  window messages; nothing is typed into whatever they switched to.
* `pump` does nothing, `poll_fds` returns 0, `wait_ms` is 16 while streams
  are open.

Upgrade path: Windows.Graphics.Capture (Windows 10 1903+) gives GPU frames
without a `WM_PRINT` round trip per frame and works for every kind of
window; it needs WinRT activation and a D3D11 device, so it is not done.

## The plugin side (core/app/remotewin.nelua)

* A window panel is a `Session` of kind `Window` in `host.world`, so pets,
  pins, Alt + drag, resizing, full screen, close, the depth test, the shadow
  board and sleeping unseen are the terminal code's. Its terminal is a small
  local one that shows status text ("waiting for the window…", "window
  refused: …", "window closed: …") until there is a picture.
  `core/app/worldview.nelua` calls `remotewin_panel` where it would draw a
  terminal; nothing else there knows about windows.
* Requests go only to an agent that greeted with version 3
  (`AgentClient:windows_ok`); to an older one `wlist`/`wopen` return false
  and emit an ERR event, and the command says "agent too old for windows:
  update ghostty-agent". Only the `CONFIG.agent` connection streams windows
  so far.
* WFRAMEs are decoded as they arrive into a CPU copy of the window (at most
  `max_w`×`max_h`×4 bytes; larger frames and size changes that are not KEY
  frames are dropped) and their rectangles noted as dirty (more than 32
  collapse into their bounding box). The frame's END is acknowledged at once,
  unless the panel sleeps unseen (30 s, as terminals) or has not been drawn
  for 2 s: then the WACK waits for the next draw and the agent stops sending.
  While a stream is live the socket is read up to 1 MiB a frame instead of
  128 KiB.
* `core/wintex.nelua` keeps one `DXGI_FORMAT_B8G8R8A8_UNORM` texture per
  stream (`D3D11_USAGE_DEFAULT`, shader resource) on Dalamud's device
  (`GuSceneDepth.ui_device` from `get_scene_depth`), created on the render
  thread when the panel is first drawn with a frame, recreated when the size
  or the device changes, released with the panel and at shutdown. Dirty
  rectangles go up with `UpdateSubresource` and a box each (a DYNAMIC
  texture mapped `WRITE_DISCARD` would copy the whole window every frame).
  Its shader resource view is the `ImTextureID`. Without the callback or the
  device the panel says it needs a newer plugin shim; the shim is unchanged.
* The picture is fitted to the panel below a 34 px title strip (the window's
  title on the left, the panel's buttons on the right) and centred, the
  panel background showing around it, as 24 × 16 textured quads
  (`ImDrawList_AddImage`) so it bends with the curve and the character
  cut-out has vertices. The first frame gives the panel the window's aspect
  (`CONFIG.windows.size`); resizing the panel later only letterboxes, the
  remote window keeps its size.
* Input, only while the panel is focused: the panel's chrome first, exactly as
  for terminals (title buttons, resize grips and Alt + drag are decided by
  worldview before the window sees the frame), and the click that focuses a
  panel stays the panel's. Over the picture, panel pixels are mapped to window
  pixels (letterbox removed): MOVE when the window pixel changes, left and
  right BUTTON down/up (a held button keeps the mouse and sends the release
  wherever the pointer is), WHEEL as ImGui's wheel × 120. A click forwarded
  to the window never counts toward the panel's double click, so double
  clicks reach the window. Keys: the panel claims the keyboard like a
  terminal (`SetNextFrameWantCaptureKeyboard`, `WantTextInput`); named keys
  (and letters, digits and punctuation under ctrl, alt or super, but not
  AltGr) go as KEY with their USB HID usage and modifiers, down and up;
  typed characters from `InputQueueCharacters` as TEXT. The toggle chords
  stay the plugin's. Losing focus releases every key and button still held
  on the window.
* WEND, a refused WOPENED or a lost connection: the panel shows why and
  closes 2 s later. A panel closed while the desktop is still choosing gets
  its late WOPENED answered with WCLOSE. Closing a live panel sends WCLOSE.
* The last WLISTR is kept (`winlist`): the Windows picker and IPC's
  `agent.windows` / `agent.apps` read it, and `/window list` logs it, one
  line a window with its source agent and key (`window #7 800x600 [firefox]
  Mozilla Firefox  @default key K`). A panel's key is that of the window id it
  asked for, else of the one listed window with its title (a panel opened by
  `run` or `match` never learns its window id); `''` when there is none.
* Short results also go to the game chat, not only the log (/xllog): a
  window opened, refused or closed, and a `/window` command that failed
  (`say` in `core/app/state.nelua`, through the shim's `chat_print`; an older
  shim without it: the log only).
* Window panels are not saved with the layout and do not survive
  `/term reload` (their streams belong to the connection, which a reload
  replaces). The Linux agent now keeps the windows (see "Window keys");
  what the plugin has to do to use that:
  1. On WOPENED for a panel, send WLIST and remember from its line for
     that window (matched by title/app, or by wid when opened by wid) the
     key: launch id, app, title. Refresh the title from later WLISTs or
     WOPENED titles as it changes, keeping the launch id.
  2. Save window panels in the world layout like terminal panels (place,
     size, pet/pin), plus the key and the match text they were first
     opened with (`run:…`, `app:…`, `desktop:…`, a name).
  3. On start and after `/term reload`, for each saved window panel send
     WOPEN `key:LAUNCH\tAPP\tTITLE`; on a refusal ("no such window") send
     the saved match text instead (launching the app again, if it was a
     launch) and save the new key.
  4. Closing a panel with its × sends WCLOSE (the app closes); a reload or
     quit just drops the connection (the app stays). Do not send WCLOSE on
     shutdown. Popped into a tab or minimized, a window panel goes back into
  the world as a pet.

## Linux: the agent is the compositor

The game runs under Wine/Proton, and the plugin core is a Windows PE DLL: it
cannot host a Unix-socket Wayland server or call Linux libraries. The
Linux-native `ghostty-agent` can, so it is the Wayland server, and the game is
its only display (`agent/capture_wayland.nelua`). No portal, no picker dialog,
no host compositor: the host desktop never sees these windows.

* One `wl_display` whose event loop fd the agent's main loop polls; the
  headless backend; the pixman renderer (software: frames land in CPU memory,
  which is what is streamed; no GPU); compositor v6, subcompositor, data
  device, primary selection, viewporter, xdg-shell v6 and xdg-decoration,
  which always answers server side (that is: no decorations; the game panel
  has chrome). Clients see one `wl_output` per window and seat `seat0` with
  pointer and keyboard.
* The socket is `$XDG_RUNTIME_DIR/ffxiv-0` (the next free `ffxiv-N` when
  taken), or `--wayland-socket NAME` / `GHOSTTY_WAYLAND_SOCKET`; the agent
  logs it. Any client started with `WAYLAND_DISPLAY=ffxiv-0` joins, so an
  app can also be started by hand from a host terminal and then pulled in by
  name (`/term window pull NAME`).
* Every `xdg_toplevel` gets its own `wlr_scene` and its own headless output,
  sized to the window geometry (so CSD shadows fall outside). A client picks
  its own size (the first configure is 0×0); one that maps without a size is
  given 1280×800. Rendering happens in `pump` when the scene has damage and
  the output has no frame pending (the headless output's 60 Hz timer), then
  the clients get frame done, so they animate at up to 60 fps and the stream
  layer rate-limits further. Direct scan-out is off: frames are always the
  composed window.
* WLIST: the line `0 0 0 launch run:COMMAND to start an app in the game`,
  then one line per mapped toplevel, `wid` counting up from 1.
* WOPEN `wid` → that window, live at once. `wid 0` + `run:CMD ARGS` → `sh -c
  CMD ARGS` in its own session with `WAYLAND_DISPLAY` set to ours,
  `XDG_SESSION_TYPE=wayland`, `GDK_BACKEND=wayland`, `QT_QPA_PLATFORM=wayland`,
  `SDL_VIDEODRIVER=wayland`, `MOZ_ENABLE_WAYLAND=1`,
  `ELECTRON_OZONE_PLATFORM_HINT=wayland`, and `DISPLAY` set to the agent's
  own Xwayland (below; unset when there is none); the stream is
  pending until a window of that process (or of a descendant, found through
  `/proc`) maps, ends with "the app exited (status N) without opening a window
  here" when it exits first, and with "the app opened no window" after 30 s.
  `wid 0` + other text → the first window whose title or app id contains it,
  waiting up to 30 s. An unmapped or destroyed window ends its streams with
  "window closed". WCLOSE asks an app launched for the stream (or
  re-attached by its key, below) to close (`xdg_toplevel.close`, X11
  `WM_DELETE_WINDOW`); other windows stay. A connection that goes away
  (plugin reload, game restart, network) closes its streams but not their
  windows or apps. Launched processes are reaped by pid only, never the
  agent's shells.
* Window keys, for re-attaching. WLISTR window lines have a sixth field,
  the launch id: `<agent run>.<n>` (hex of the agent's start time and pid,
  then a counter) for the window a `run:`/`app:`/`desktop:` launch opened,
  empty for others. WOPEN `wid 0` + `key:LAUNCH\tAPP\tTITLE` (or
  `key:LAUNCH`, the column as is, for a launched window) opens the window
  that fits best among those nobody streams: the same launch id
  fits whatever the title became; else APP must equal the window's app
  (when given) and an equal title beats one that contains the other.
  Nothing fitting within 5 s ends the stream with "no such window (the app
  is not running: launch it again)". A launch id of an earlier agent run
  never matches (its apps died with it).
* X11 apps: wlroots' Xwayland, lazily. The agent listens on the next free X
  display at start (logged: `X11 apps: DISPLAY=:N or
  DISPLAY=$XDG_RUNTIME_DIR/ffxiv-0-x11`); the Xwayland server starts when
  the first X11 client connects (logged with how long it took) and stops 10 s
  after the last one leaves. `$XDG_RUNTIME_DIR/<socket>-x11` is a symlink to
  the display's socket, a name that does not change with the number (libxcb
  accepts a socket path as `DISPLAY`). `GHOSTTY_XWAYLAND=off` leaves Xwayland
  out, `=eager` starts it with the agent; no `Xwayland` binary means no X11.
  A mapped X11 toplevel is a window like an xdg one (WLIST with its WM_CLASS
  class as app, streams, input, close as `WM_DELETE_WINDOW`), rendered at
  scale 1 (X11 apps draw at 1x; scaling their buffers would only blur them).
  The client pid for `run:` matching is `_NET_WM_PID`. Position and size
  requests are granted as asked. An override-redirect window (menu, tooltip)
  is drawn into the output of the window it belongs to (its transient-for
  parent's, else the X11 window of its process it lies over, else one of its
  process, else the focused X11 window), at its root position relative to
  that window's. The pointer over no surface still goes to the X11 window,
  so a click outside ends a menu's grab.
* Installed apps (`agent/desktop_entries.nelua`). WLIST with the payload
  `apps` answers WLISTR with one line per app instead of the windows:

  ```
  app\tID\tNAME\tICON\tCATEGORIES\n              a graphical app
  term\tID\tNAME\tICON\tCATEGORIES\tCOMMAND\n    Terminal=true: meant for a terminal panel
  desktop\tNAME\tNAME\t\t\n                      an installed nested compositor (desktop:NAME)
  ```

  ID is the desktop file id without `.desktop`; NAME the unlocalized
  `Name`; CATEGORIES as the file gives them (`Utility;TextEditor;`); unknown
  first fields are to be skipped. Entries come from `$XDG_DATA_HOME`,
  `$XDG_DATA_DIRS` and both Flatpak export directories (first file of an id
  wins; `NoDisplay`/`Hidden`/non-Application entries left out), sorted by
  name. ICON is an absolute PNG path under
  `$XDG_CACHE_HOME/ghostty-agent/icons` (`~/.cache/...`), `<ID>-<size>.png`,
  empty when the app has no icon: the game runs in XIVLauncher's Flatpak,
  which sees the home directory but not `/usr/share` or `/var/lib/flatpak`,
  so the agent copies PNG icons there and renders SVG/XPM ones at 128 px
  with the first of `rsvg-convert`, `magick`, `convert` on `PATH`. Icon
  names are looked up in the hicolor, Adwaita, breeze and AdwaitaLegacy
  themes (apps context first, then categories, legacy, devices, places,
  status, mimetypes; 128 px first), then `/usr/share/pixmaps`. Missing icons
  are made by one background job per listing, so a path can name a file
  that appears a moment later; the plugin should retry a missing file. An
  agent without an app list (Windows, macOS, older) answers `apps` with an
  empty WLISTR (older agents: the window list, whose first field is a
  number). Remote agents on other machines would have to send icon bytes
  over the protocol instead of paths; not designed yet.
* WOPEN `wid 0` + `app:NAME`: NAME is a desktop id (with or without
  `.desktop`, any case) or, fuzzily, a name (whole name, prefix, word prefix,
  substring, letters in order; also the id's last word and the program
  name). Its `Exec` (field codes dropped, `%i`/`%c` expanded) runs as
  `run:` would. A Terminal=true app is refused with its command, so the
  plugin can open it as a terminal panel instead.
* WOPEN `wid 0` + `desktop:[NAME [ARGS]]`: a nested Wayland compositor as
  one window (`env WLR_RENDERER=pixman WLR_NO_HARDWARE_CURSORS=1 NAME
  ARGS`, since ours offers only shared-memory buffers to it). No NAME: the
  first installed of labwc, sway, wayfire, river, weston, Hyprland. `cage
  APP` runs one app (`--` added).
* Popups are not clipped: an xdg_popup may be placed anywhere within 600
  logical px around its window (its positioner is unconstrained against that
  box, not the window), and X11 menus open on an X screen of 3840×2160 (one
  extra output nothing draws, so GTK/Qt on X11 do not keep menus inside
  their window). Each window's output is sized to the window plus its shown
  popups (clamped to the same margin) and placed at their top-left corner;
  WFRAME pictures are that rectangle and WGEOM says where the window and
  each popup are in it. WINPUT coordinates are pixels of that picture.
* Text input: the compositor offers text-input-v3. When the focused
  surface's client has enabled one, TEXT is sent as `commit_string` (then
  `done`), any Unicode, with newline and tab as the Enter and Tab keys;
  otherwise TEXT goes through the keymap as below.
* Clipboard: apps' copy requests are granted (`wl_data_device`, and X11
  through Xwayland's bridge; the primary selection too). When no app owns
  the selection, it is the agent's own source, which reads the host
  clipboard (the agent's `wl-paste`, or `--clipboard-file`) when an app
  pastes. When an app copies text, the agent reads it, puts it on the host
  clipboard (`wl-copy` / the file) and takes the selection back with its
  own source. The game's copies (CLIP_SET) already land on the host
  clipboard and also make the agent's source the selection again; the
  game's pastes (CLIP_GET) read the host clipboard, so text copied in an
  app pastes in the game. Non-text selections stay among the apps.
* Input: the stream that gets input gets the keyboard focus (one toplevel at a
  time). Pointer events go to the surface under the point in that window's
  scene (popups included), with `BTN_LEFT/RIGHT/MIDDLE`. WHEEL `dy` is 1/120
  notches, +dy away from the user (scroll up), which is a negative Wayland
  vertical axis value: sent as `value120 = -dy` and `-dy × 15 / 120` axis
  units (libinput's 15 per notch); +dx scrolls right. KEY maps USB HID
  usages to evdev keycodes (letters, digits, Enter/Esc/Backspace/Tab/Space,
  punctuation, F1–F24, arrows, Home/End/PgUp/PgDn/Insert/Delete, keypad,
  modifiers) and presses the `mods` modifiers around the key; lone modifier
  keys are not played. TEXT looks each codepoint up in the xkb keymap (layout
  `us` or `GHOSTTY_XKB_LAYOUT`) at level 1, then level 2 with Shift; newline
  and tab are Enter and Tab.

Limits, all current:

* TEXT to a client without text-input-v3 (X11 apps, some toolkits) reaches
  only characters the layout types at level 1 or 2; others (for "us":
  accented letters, emoji) are dropped with one log line.
* The primary selection (middle-click paste) works between apps but is not
  bridged to the host.
* Software rendering (pixman) only; GL clients render through their own
  software fallback.
* Single-instance apps (GApplication/D-Bus activation) that are already
  running on the host desktop hand the request to that instance, and the
  window opens there instead; the launch then ends "without opening a window
  here". Use their standalone/new-instance flag.
* Apps launched by the agent die with it (they lose their display); the agent
  does not kill them on exit itself.

## macOS backend (agent/capture_mac.nelua)

Compiles (arm64 and x86_64 Mach-O, `MAC=1 tools/build.sh`); **never run on
a Mac**. Everything below is the design as written, not observed behaviour.

No SDK: the agent is cross-compiled with Zig (`tools/zig-cc-mac.sh`,
`tools/zig-cc-mac-x64.sh`), which has macOS libc headers and libSystem
stubs but no framework headers. Frameworks are `dlopen`ed from
`/System/Library/Frameworks` and called through typed function pointers;
Objective-C goes through `objc_msgSend` cast to each message's exact
signature (no message used returns a struct, so no `_stret`). Completion
handlers are Block literals built by hand on the stack (layout in
`agent/capture_mac_logic.nelua`, `MacBlock`); the stream output/delegate is a
class registered at run time (`GhosttyAgentCaptureOutput`: NSObject, a `ctx`
ivar, `stream:didOutputSampleBuffer:ofType:`, `stream:didStopWithError:`).

* **List**: `CGWindowListCopyWindowInfo(OnScreenOnly | ExcludeDesktopElements)`,
  layer 0 windows at least 16×16 points, not the agent's own; sizes are
  points × the backing scale of the display under the window's centre. The
  first line is `0 0 0 launch run:APP …`; missing permissions add `note`
  lines (wid 0).
* **Open**: a wid (any window the server knows); `run:NAME` runs
  `/usr/bin/open -a NAME` (posix_spawn, no shell) and stays pending until a
  window of an app named NAME appears (30 s, then ended); any other text is
  the first on-screen window whose title or app contains it. `wid 0` with no
  text fails: macOS has no picker to hand to.
* **Frames**, macOS 12.3+: ScreenCaptureKit. `SCShareableContent` finds the
  `SCWindow` by id, `SCContentFilter initWithDesktopIndependentWindow:`
  (other windows on top do not show; windows on other Spaces still stream),
  `SCStreamConfiguration` at the window's pixel size, BGRA, at most 60 fps,
  no cursor, queue depth 3, one serial dispatch queue per stream. The sample
  callback skips buffers whose `SCStreamFrameInfoStatus` is not Complete,
  copies the `CVPixelBuffer` rows (read-only lock) into its own buffer, swaps
  it into the shared slot under a mutex and writes a byte to a self-pipe the
  main loop polls; `frame()` swaps the shared slot out. No copy happens under
  the lock and nothing is polled: frames reach the loop as they arrive.
  Pending until the first frame (10 s, then ended). Every 0.5 s the window's
  bounds are read again: gone ends the stream ("window closed"), a new size
  reconfigures it (`updateConfiguration:`).
* **Frames**, before 12.3: `CGWindowListCreateImage` (deprecated; nominal
  1x resolution) taken when the generic layer wants a frame.
* **Input**: window pixels map to global points through the latest frame's
  size and the window's bounds (refreshed when older than 100 ms), so Retina
  needs no extra factor. Mouse: `CGEventCreateMouseEvent` (moves, drags
  while held, left/right/other down/up with a click count for double
  clicks), wheel: `CGEventCreateScrollWheelEvent2` in lines (a partial notch
  scrolls one), keys: USB HID → `kVK_*` with ctrl/shift/alt/super →
  Control/Shift/Option/Command flags, text: `CGEventKeyboardSetUnicodeString`
  in chunks of at most 20 UTF-16 units. Events go to the window's process
  (`CGEventPostToPid`), so the user's cursor stays put; clicks also carry the
  undocumented window-under-pointer fields (91, 92). Some apps ignore
  pid-posted mouse events; FOCUS (`NSRunningApplication
  activateWithOptions:`) brings the app forward and from then on posts that
  stream's events to the HID tap (`CGEventPost`), which moves the real
  cursor.
* **Permissions**: Screen Recording for titles and capture
  (`CGPreflightScreenCaptureAccess`; the system prompt is asked for once),
  Accessibility / event posting for input (`CGPreflightPostEventAccess`, else
  `AXIsProcessTrusted`). They belong to the agent binary, or to the terminal
  app that started it. Without Screen Recording, WLIST says so and opens end
  with the reason; without Accessibility, WLIST says so and input is dropped
  (one line on stderr).
* **Limits**: frames are the full pixel size (the generic layer scales down
  to `max_w`×`max_h`). The pid-posted path cannot reach windows of apps that
  only read the HID stream; FOCUS is the way out. The agent has no
  NSApplication or run loop; ScreenCaptureKit works from dispatch queues,
  and `CGMainDisplayID()` is called first to open the window server
  connection.

## Using it

```
/window                         the Windows picker (again: closes it)
/window list [@agent]           the picker too, with a fresh list (also logged: wid, size, app, title, agent, key)
/window pull                    the picker too
/window pull match [@agent]     open one as a pet
/window pull #wid               by id from the list
/window run CMD... [@agent]     the agent starts CMD and streams its window (match text "run:CMD...")
/window close                   the focused window panel (else the newest)
/window desktop                 reserved (a whole remote desktop); says so for now
/term pin …                     on a focused window panel: moves it, keeping its size
/term pin toggle                on a focused world panel: pin <-> pet where it is
```

The **Windows picker** (`core/app/winpicker.nelua`) is a small ImGui window
in the dropdown's glass. It asks the agent for a fresh list when it opens
(Refresh asks again) and shows the last one: each open window, pulled onto a
pet with a click; a **Run:** box whose Enter (or Run) does `/window run TEXT`;
the apps a newer agent lists (`app` lines), started by sending WOPEN with the
match text `app:ID` (an assumption until the agent side defines it); and
**Let the desktop choose** (WOPEN with nothing: the agent's own picker, which
is what `/window pull` without arguments used to do). A pick that works
closes the picker; one that fails says why at its bottom and in the chat.

Every world panel, terminal or window, has a pin <-> pet title button next to
pop-in: a paw on pins (it becomes a pet), a push pin on pets (it is pinned in
the world right where it is shown, facing the same way). Its own size stays
where it had one set (window panels always do).

`/window` is a command of its own (`CONFIG.host.verb_commands`, registered
through the shim's `command_add_tagged`; a shim from before it logs that once
and registers only `/term`). `/term window list | pull … | close` does the
same and points at `/window` once per session. `/ask [question]` and
`/agent ask [question]` are `/term ask` the same way.

`@agent` may only name `default` so far. `lua/windows.lua` (`CONFIG.windows`)
holds the sizes asked for (`max_w`, `max_h`, default 1920×1200), `fps` (30),
the panel's `pixels_per_yalm` (700), `width` (1600 panel pixels), `opacity`,
and `auto`: `/term window pull` arguments run once the character is loaded.

Clicking a window panel focuses it; while focused the mouse and keyboard go
to the remote window. Esc twice within half a second (or clicking outside)
gives them back; the first Esc reaches the window.

### IPC for other plugins

Another plugin can do the same through `GhosttyDalamud.v1.Call`:
`window.list`, `window.open` (`run`, `match` or `wid`, optional `pin`),
`window.close`, `window.focus`, `window.place`, `window.hide`,
`window.toggle_pet`, `agent.windows` (+ `.refresh`), `agent.apps`,
`terminal.new`, `focus.get`, `focus.cycle`, `agent.status` and `status`,
as JSON. Reads answer from the last frame's snapshot; changes are queued and
run by the next frame through the same `window_*` functions as the commands
above. Methods, examples and the threading are in [IPC.md](IPC.md). Not yet
observed in game.

## Verified

Host tests only (`tests/run.sh`), nothing in game or on a real desktop:

* `test_wincodec`: tile diff, QOI both ways, WFRAME packing and parsing,
  `wincodec_downscale`.
* `test_agent_windows`: the whole agent path over TCP against the synthetic
  backend (`--windows test`): WLIST, WOPEN by id and by match, WOPENED fields,
  a KEY frame and deltas rebuilt to the backend's exact pixels, a scaled
  stream, flow control (no third `seq` without WACK), an unchanged window
  sending nothing more, every WINPUT kind with scaled and clamped
  coordinates, WCLOSE, WEND, open failures, another connection unable to see
  or touch a stream, a disconnect closing streams, and an agent run with
  `--windows off` refusing with the reason.

* `test_capture_win32`: the Win32 backend's pure parts (HID → VK, key
  lParams and characters, mouse words, UTF-16, list lines, matching).

Under Wine only (wine-xiv-staging 10.8, throwaway prefix, notepad on an
Xvfb display), never on real Windows:

* `tests/smoke_capture_win32.nelua` (the backend alone): notepad listed with
  its exe name and client size (942×659) and opened by match `notepad`;
  frames at the pace asked (about 45 `frame()` a second with 16 ms sleeps),
  7 distinct frames in 3 s of an idle window (the caret blinking), about
  6 to 7 ms a capture at that size. Wine's `PrintWindow` returned success but drew
  nothing for another process's window in every capture; all frames came
  from the window-DC `BitBlt` fallback. A click, TEXT (including é and an
  emoji as a surrogate pair), KEY enter, TEXT and KEY backspace arrived in
  that order: the Edit control read back through `WM_GETTEXT` held
  exactly what was typed, and the captured picture showed it. With the
  first version, which posted messages, the newline arrived after the
  second line of text; that is why messages are sent now.
* `tests/smoke_windows_win32.nelua` against `ghostty-agent.exe --windows
  win32` (the Windows loop's window path, first run): WLIST, WOPEN by match
  (942×659, title "Untitled - Notepad"), a KEY frame and deltas rebuilt by
  the client (7 seqs in 3 s, idle window), a click, TEXT, KEY enter and TEXT
  that showed up in the next frames, WCLOSE.
* Without a display (no `DISPLAY`) Wine lists and opens windows but every
  capture path returns black.

Not observed anywhere: FOCUS and the SendInput path (not run: it would have
taken the foreground on the user's desktop), the wheel, a window closing
while streamed, minimised windows, DPI scaling, DirectX or Chromium windows,
real Windows.

* `test_remotewin`: the plugin side against a fake version 3 agent on a
  socketpair, a fake ImGui and a fake texture table: WLISTR in the log,
  WOPEN fields (and `run:`), a pending pet, WOPENED, a KEY and a delta frame
  rebuilt in the CPU copy, texture creation on the reported device and one
  upload per dirty box, WACK after END and held while asleep, the panel
  taking the window's aspect, the 24 × 16 textured quads covering exactly the
  letterboxed picture with the view as texture id, MOVE / BUTTON / WHEEL /
  KEY / TEXT mapping, the focusing click and the resize grip keeping their
  clicks, double clicks reaching the window, Esc twice, an older shim, WEND
  closing after 2 s with the texture released, WCLOSE for a closed panel and
  a late WOPENED, a lost connection, and a version 2 agent refused.

`ghostty_core.dll` cross-compiles with the window code. Not yet observed in
game: the texture on Dalamud's device, the view accepted as `ImTextureID` by
Dalamud's DX11 ImGui renderer, the depth test's shader sampling it, upload
cost and frame pacing, and input played back into a real window.

Linux Wayland backend, observed 2026-09-19 on this project's dev host (Bazzite
/ Fedora 44, host wlroots 0.20.2, libwayland-server 1.26.0, xkbcommon 1.13.1,
pixman 0.46.2; agent built with zig cc), with `yad` 9.3 (GTK 3.24.52) as the client:

* `test_capture_wayland`: the HID table, codepoint lookup against real `us`
  and `de` keymaps, `run:` parsing, WLIST lines, matching.
* `test_wayland_compositor` (backend driven directly): `run:yad --text-info
  --editable --width=640 --height=400` mapped 0.2 s after WOPEN; the first
  frame was 640×437 (the window geometry: GTK3's CSD titlebar included, its
  shadow excluded) with ~280k pixels unlike the first; a click into the text
  view, TEXT `echo hi\n` and KEY Shift+h put "echo hi" and "H" on two lines
  (332 pixels changed, 3 new frames in the 2 s after); WLIST listed
  `1 640 437 yad ghostty-wayland-test`; closing the stream closed yad and
  the window left the list; `run:exit 3` ended with status 3. No window
  appeared on the host desktop.
* Through the agent over TCP (a manual run, same host, `--windows wayland`):
  WOPEN `run:yad …` answered WOPENED sid 1, a 500×337 KEY frame followed,
  a click and TEXT produced 4 delta frames, WCLOSE closed the app.

* `test_wayland_compositor`, 2026-09-19, X11: `run:env GDK_BACKEND=x11 yad
  --text-info --editable --width=500 --height=300` started Xwayland lazily
  (Xwayland 24.1 on this host; "ready after" 67 and 124 ms in two runs, glamor
  unavailable so software) and mapped 0.19 to 0.40 s after WOPEN, Xwayland
  start included; the first frame was 500×300 (scale 1), WLIST listed `2 500
  300 Yad ghostty-x11-test`, a click and TEXT `typed into X11\n` changed 504
  pixels and showed the text in the saved picture, closing the stream closed
  yad. Override-redirect menus were not exercised by this test.
* `test_desktop_entries`, 2026-09-19: parsing, Exec field codes, lookup by
  id and fuzzy name, list lines, icon lookup in a made-up tree, and the cache
  jobs: a PNG copied, an SVG rendered to a 128×128 PNG by rsvg-convert
  (linuxbrew) and, with `PATH=/usr/bin:/bin`, by ImageMagick 7 `magick`.
* `test_wayland_compositor`, 2026-09-19, apps: WLIST `apps` on this host
  listed 89 apps; a lookup run found icons for 85 (3 entries have no `Icon`,
  one names an icon no theme has), 76 before the non-apps contexts were
  added. With a made-up data home, its app was listed with its icon path and
  the icon was a PNG 0.05 s later; `app:ghostty test view` launched it by
  fuzzy name; an unknown name was refused. `desktop:cage yad …` ran cage
  (the only nested compositor installed here: no sway, labwc, wayfire,
  river, weston or Hyprland, so `desktop:sway|labwc` is not run) as our
  client: one 2560×1440 window showing yad inside cage. An unknown desktop
  name was refused.
* `test_wayland_compositor`, 2026-09-19, popups: a right click 30 px from
  yad's right edge opened GTK's context menu; with the xdg window (1280×800
  at scale 2) the picture grew to 1604×946 with the window at 0,0 and the
  menu at 1252,402 352×544 (menu pixels outside the window, saved as
  `xdg-menu.png`); with the X11 window (500×300) to 638×405, menu at 471,151
  167×254 (an override-redirect window, `x11-menu.png`). Escape closed each
  and the picture went back to the window alone. Before the big X screen
  output, GTK on X11 kept its menu inside the 500×300 window.
* `test_e2e_wayland`, 2026-09-19, WGEOM over TCP: a WGEOM with the window
  alone came with the first frame; after a right click near the edge a
  WGEOM with window 0,0 1120×720 and a menu at 1102,362 352×544, and a
  1454×906 picture; after Escape the window alone again.
* `test_wayland_compositor`, 2026-09-19, keys: after `release` the yad
  window stayed and was listed with launch id `6aaeb5983ff6c.1`; WOPEN
  `key:6aaeb5983ff6c.1\tyad\tghostty-wayland-test` was live at once; a key
  for a missing app ended after 5.0 s; WCLOSE on the re-attached stream
  closed yad. Pure checks of key parsing and scoring in `test_capture_wayland`.
* `test_e2e_wayland`, 2026-09-19, persistence over TCP: the client
  disconnected, a new connection's WLIST still listed the app with its
  launch id, and WOPEN `key:…` opened it again as a new stream with a
  1120×720 KEY frame; stopping the agent then ended the app.
* `test_e2e_wayland`, 2026-09-19, GTK4 regression (outputs at 60 Hz): `run:flatpak
  run org.gnome.TextEditor --standalone` opened a 1400×1040 window that stayed
  mapped for 5 s (8 frames) and closed with WCLOSE.
* `test_wayland_compositor`, 2026-09-19, text input and clipboard, read
  back from `yad --entry` (GTK3, which enables text-input-v3): TEXT
  `héllo ✓ 日本 Ω\n` came out exactly; ctrl+v pasted the host clipboard's
  text (a test function standing in for the agent's); text typed, selected
  (ctrl+a) and copied (ctrl+c) in the app reached the host clipboard,
  "copied in the app ✓".
* `test_e2e_wayland`, 2026-09-19, clipboard through the agent
  (`--clipboard-file`): ctrl+a ctrl+c in yad put its text in the file;
  CLIP_SET `from the game ✓` from the plugin's client, then ctrl+a ctrl+v
  ctrl+a ctrl+c in yad, left exactly that text in the file. The host
  desktop's own clipboard (wl-copy/wl-paste) was not exercised.
* `test_e2e_wayland` (in `tests/run.sh`): the plugin's own agent client
  (`core/agent_client.nelua`, decoding as `core/app/remotewin.nelua` does)
  against a real agent run with `--windows wayland --wayland-socket …` and no
  `DISPLAY`: WOPEN `run:yad …`, a 560×397 KEY frame and deltas with WACK
  after each END, a click and TEXT "typed from FFXIV\n" showing in the
  rebuilt picture (631 pixels changed); SIGTERM to the agent logged
  "stopping" and ended the app it had launched.

Not observed: any other client (GTK4, Qt, Electron, terminals), popups and
menus, resizes, wheel scrolling having a visible effect, the game side.

* `test_capture_mac`: the macOS backend's pure parts (keycode table, flags,
  event types, point mapping, Block layout, `run:` parsing, list lines,
  UTF-16 chunks, CGImage layouts).

The macOS agent (`ghostty-agent-macos-arm64`, `-x86_64`) cross-compiles
with the ScreenCaptureKit backend and is a valid Mach-O; it has never been
run on a Mac, so no part of the macOS backend is verified.
