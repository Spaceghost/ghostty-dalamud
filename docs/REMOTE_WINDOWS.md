# Remote windows

Any desktop window on a machine running `ghostty-agent` (Linux, Windows,
macOS) can be pulled into the game as a world panel: a pet, a pin, anything a
terminal panel can be. The agent captures the window, sends only what changed,
and plays the plugin's mouse and keys back into it.

```
 FFXIV (plugin core)                               ghostty-agent (any desktop)
 ┌───────────────────────────────┐   TCP     ┌──────────────────────────────────┐
 │ core/app/remotewin.nelua      │  WOPEN →  │ agent/windows.nelua              │
 │  Session kind Window          │ ← WFRAME  │  streams, tile diff, flow control│
 │  core/wintex.nelua (D3D11)    │  WACK  →  │ agent/capture_*.nelua (backends) │
 │  core/wincodec.nelua (decode) │  WINPUT → │  portal+PipeWire │ Win32 │ macOS │
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
| 24 | WLISTR | lines `wid\tw\th\tapp\ttitle\n`; wid 0 = "ask the desktop to pick" |
| 25 | WOPENED | req u32, sid, w u16, h u16, title UTF-8 (sid 0: failed, the text says why) |
| 26 | WFRAME | sid, seq u32, w u16, h u16, flags u8, nrect u16, rects… |
| 27 | WEND | sid, reason UTF-8 (window closed, capture refused, …) |

WOPENED answers WOPEN by its client-chosen `req`, and may come much later
(the user is choosing in the desktop's picker) and out of order. `wid 0` asks the backend to let
the user choose (the portal's picker on Wayland); a backend that can list
windows may also treat `wid 0` + match text as "first window whose title or
app contains the text, case-insensitive".

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
| `agent/capture_portal.nelua` | agent (Linux) | xdg-desktop-portal ScreenCast + RemoteDesktop, PipeWire; libdbus and libpipewire are dlopened |
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
stay pending (the portal's picker is up); the WOPENED goes out when it
settles.

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

## Using it

```
/term window list [agent]     windows the agent can see (wid, size, title)
/term window pull [match]     open one as a pet (no match: the desktop's picker)
/term window pull #wid        by id from the list
/term pin …                   pins work on window panels like on terminals
```

Clicking a window panel focuses it; while focused the mouse and keyboard go
to the remote window. Esc twice (or clicking outside) gives them back.

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
