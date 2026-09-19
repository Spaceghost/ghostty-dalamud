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
| 11 | WLIST | – |
| 12 | WOPEN | req u32, wid u32, max_w u16, max_h u16, fps u8, then optional UTF-8 match text |
| 13 | WACK | sid, seq u32 |
| 14 | WINPUT | sid, kind u8, body (below) |
| 15 | WCLOSE | sid |

agent → client

| type | name | payload |
|---|---|---|
| 24 | WLISTR | lines `wid\tw\th\tapp\ttitle\n`; a wid 0 line describes what WOPEN with wid 0 does |
| 25 | WOPENED | req u32, sid, w u16, h u16, title UTF-8 (sid 0: failed, the text says why) |
| 26 | WFRAME | sid, seq u32, w u16, h u16, flags u8, nrect u16, rects… |
| 27 | WEND | sid, reason UTF-8 (window closed, capture refused, …) |

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
  streams are closed when it goes. Windows do not outlive their client.
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
* Window panels are not saved with the layout and do not survive
  `/term reload` (their streams belong to the connection, which a reload
  replaces). Popped into a tab or minimized, a window panel goes back into
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
* The socket is `$XDG_RUNTIME_DIR/ghostty-0` (the next free `ghostty-N`
  when taken), or the name in `GHOSTTY_WAYLAND_SOCKET`; the agent logs it.
  `capture_wayland_configure(socket, layout)` sets both before the backend
  starts, for `--wayland-socket` / `--xkb-layout` flags in the agent (not
  wired up yet). Any client given `WAYLAND_DISPLAY=ghostty-0` joins.
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
  `ELECTRON_OZONE_PLATFORM_HINT=wayland`, and `DISPLAY` unset; the stream is
  pending until a window of that process (or of a descendant, found through
  `/proc`) maps, ends with "the app exited (status N) without opening a window
  here" when it exits first, and with "the app opened no window" after 30 s.
  `wid 0` + other text → the first window whose title or app id contains it,
  waiting up to 30 s. An unmapped or destroyed window ends its streams with
  "window closed". Closing a stream asks an app launched for it to close
  (`xdg_toplevel.close`); other windows stay. Launched processes are reaped
  by pid only, never the agent's shells.
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

* No Xwayland yet: X11-only apps do not show up (DISPLAY is unset for them).
* Popups are constrained to the window and clipped to it.
* TEXT reaches only characters the layout types at level 1 or 2; others (for
  "us": accented letters, emoji) are dropped with one log line. text-input-v3
  is the way to more.
* Software rendering (pixman) only; GL clients render through their own
  software fallback.
* Single-instance apps (GApplication/D-Bus activation) that are already
  running on the host desktop hand the request to that instance, and the
  window opens there instead; the launch then ends "without opening a window
  here". Use their standalone/new-instance flag.
* Apps launched by the agent die with it (they lose their display); the agent
  does not kill them on exit itself.

## Using it

```
/term window list [@agent]           windows the agent can see (in the log: wid, size, app, title)
/term window pull [match] [@agent]   open one as a pet (no match: the agent's own choice)
/term window pull #wid               by id from the list
/term window pull run CMD...         the agent starts CMD and streams its window (match text "run:CMD...")
/term window close                   the focused window panel (else the newest)
/term pin …                          on a focused window panel: moves it, keeping its size
```

`@agent` may only name `default` so far. `lua/windows.lua` (`CONFIG.windows`)
holds the sizes asked for (`max_w`, `max_h`, default 1920×1200), `fps` (30),
the panel's `pixels_per_yalm` (700), `width` (1600 panel pixels), `opacity`,
and `auto`: `/term window pull` arguments run once the character is loaded.

Clicking a window panel focuses it; while focused the mouse and keyboard go
to the remote window. Esc twice within half a second (or clicking outside)
gives them back; the first Esc reaches the window.

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

Not observed: any other client (GTK4, Qt, Electron, terminals), popups and
menus, resizes, wheel scrolling having a visible effect, the game side.
