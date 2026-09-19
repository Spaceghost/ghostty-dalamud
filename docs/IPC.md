# IPC for other plugins

`GhosttyDalamud.v1.Call` lets another Dalamud plugin (XivDesktop, for one)
list, open, close, focus, hide and place remote-window panels
([REMOTE_WINDOWS.md](REMOTE_WINDOWS.md)), open world terminals, read the
agent's window list and move the keyboard between world panels. It is one Dalamud call gate:
a JSON string in, a JSON string out.

**Status: host tests only. Not yet observed in game.**

```csharp
var call = pi.GetIpcSubscriber<string, string>("GhosttyDalamud.v1.Call");
string reply = call.InvokeFunc("""{"method":"window.list","caller":"XivDesktop"}""");
```

The channel is registered with the other `GhosttyDalamud.v1.*` providers
while the plugin is active, and only when the core exports `gu_call` (an
older core or loader: `InvokeFunc` throws Dalamud's "not registered" error,
as for a missing plugin).

## Requests and responses

```json
{"method": "window.open", "params": {"run": "yad --calendar"}, "caller": "XivDesktop"}
```

* `method`: one of the methods below.
* `params`: an object (may be left out or `null` when a method takes none).
* `caller`: optional, the asking plugin's name (also accepted as
  `params.caller`). It is written to the log line of a panel opened this way
  ("… (for XivDesktop)") and to the log line of a failed change.

A response is always `{"ok": true, "result": …}` or
`{"ok": false, "error": "why"}`. Errors are plain text for people; test `ok`,
not the text.

Strings are checked: at most 1024 bytes, no control characters. JSON is
parsed strictly (RFC 8259: no comments, no trailing commas, a lone surrogate
escape is refused, nesting at most 64 deep). A response is at most 64 KiB;
anything larger comes back as `{"ok":false,"error":"response too large"}`.

## Threads, and why changes are queued

A plugin calls from its own thread: its `Draw`, its framework tick, a task.
The core and its Lua state belong to ghostty's own `UiBuilder.Draw`
(`gu_frame`), so a call never touches them. Instead
(`core/app/ipc.nelua`, `lua/ipc.lua`):

* A call runs in a second, small Lua state that holds only `lua/json.lua`,
  `lua/ipc.lua` and three functions, under a lock. The lock is held only for
  that call (decode, check, encode: microseconds) and, on the frame's side,
  to swap a queue and publish a string. Calls from several threads are
  serialized; no call waits for a frame.
* **Reads** (`window.list`, `agent.status`, `agent.windows`, `agent.apps`,
  `focus.get`, `status`) answer at once from a snapshot the frame publishes
  at its end. They are at most one frame old.
* **Changes** (`window.open`, `window.close`, `window.focus`,
  `window.place`, `window.hide`, `window.toggle_pet`,
  `agent.windows.refresh`, `terminal.new`, `focus.cycle`, `keys.reserve`) are checked, given
  a request id and queued. The response
  says only that: `{"queued": true, "request": 1726732800001}`. At the end of
  the next frame ghostty runs them in order, in its own Lua state, through
  the same functions as `/window` and the title buttons
  (`core/app/remotewin.nelua`: `window_open`, `window_close`,
  `window_place`; `core/app/worldview.nelua`: `world_panel_focus`,
  `world_panel_hide`, `world_toggle_pet`, `world_terminal_new`). The outcome shows in
  `window.list`: `requests` holds the last 16 results, and `rev` changes.
  At most 64 changes wait; the 65th before a frame is refused ("too many
  changes waiting").

So to open a window and learn its panel id: call `window.open`, keep
`request`, then poll `window.list` (cheap) until `rev` changes and a
`requests` entry carries that id. Request ids are opaque and increasing;
they do not repeat after `/term reload` or a reloaded core.

While ghostty is disabled (`CONFIG.disabled`, the kill switch) no frame runs:
reads return the last snapshot and changes wait. Before the first frame a
read answers `{"ok":false,"error":"ghostty is starting; ask again after the next frame"}`.

## Methods

### window.list

The window panels, oldest first, and the results of recent changes.

```json
{"method": "window.list"}
```
```json
{"ok": true, "result": {
  "rev": 7,
  "windows": [
    {"id": 12, "sid": 5, "title": "Yad Window", "app": "yad", "w": 640, "h": 400,
     "state": "live", "kind": "pet", "anchor": "pet", "hidden": false, "focused": false,
     "agent": "default", "key": "yad-1"}
  ],
  "requests": [
    {"request": 1726732800001, "method": "window.open", "ok": true, "result": {"id": 12}},
    {"request": 1726732800002, "method": "window.place", "ok": false, "error": "pin: usage: …"}
  ]
}}
```

* `rev`: changes whenever anything in `windows` or `requests` changes (it is
  not a count; compare for equality).
* `id`: the panel id every other method takes. `sid`: the agent's stream id
  (0 while pending).
* `title`: the window's title once the agent opened it, else `""`.
  `app`: what was asked for: the program of a `run` command (`"yad"` for
  `/usr/bin/yad --calendar`), the `match` text, or `""` for a `wid` or the
  agent's own choice.
* `w`, `h`: the size of the frames arriving (0 before the first).
* `state`: `pending` (asked, not opened yet), `live`, `ended` (the window
  closed or the connection went; the panel closes 2 s later; also while a
  closed panel glitches out).
* `kind`: `pet` (floats beside the character), `pin` (placed in the world:
  here, me, target, orbit …), `full` (full screen), `tab` (popped into the
  dropdown for a moment; window panels go back out).
* `anchor`: the world anchor as it is, also while `full` or `tab`: `pet`,
  `pin` (fixed in the world), `me` or `target` (following a character),
  `orbit`, or `none`.
* `hidden`: hidden by `window.hide` (not drawn, not streamed).
* `focused`: the panel has the keyboard.
* `agent`: the agent streaming it (`default`, the only one so far).
  `key`: the window's stable key from the agent's last list (`agent.windows`)
  where the agent sends one: the entry of the window id it asked for, else the
  one entry with its title; `""` when none.
* `requests[]`: `{request, method, ok, result | error}`; `window.open`'s
  result is `{"id": panel}`, the others' `{}`.

### window.open

```json
{"method": "window.open", "params": {"run": "yad --calendar", "pin": "here"}, "caller": "XivDesktop"}
```
```json
{"ok": true, "result": {"queued": true, "request": 1726732800001}}
```

At most one of:

* `run`: the agent starts the command and streams its window (the Linux
  compositor backend; `/window run CMD`).
* `match`: a window whose title or app contains the text.
* `wid`: a window id from the agent's list (`/window list` shows it in the log).
* none: the agent's own choice (a desktop picker where it has one).

Optional: `pin` places the panel as `/term pin` takes it (`"here"`, `"me 2 1.7"`,
`"target"`, `"orbit 3.5"` …; default: a pet). A pin that fails fails the
open, and no window is asked for. `agent` may only be `"default"` so far.

The result in `requests`: `{"id": panel}` once the panel exists (still
`pending` until the agent answers), or why not: `the agent is not
connected`, `agent too old for windows: update ghostty-agent`, `no player
(log in first)`, `pin: …`, `NAME is on CONFIG.windows.never`. A window the
agent then refuses shows as `ended` with the reason on the panel.

### window.close

```json
{"method": "window.close", "params": {"id": 12}}
```

Closes the panel (it glitches out) and its stream.

### window.focus

```json
{"method": "window.focus", "params": {"id": 12}}
```

Gives the panel the keyboard exactly as a click on it would: it becomes the
focused world panel, no ImGui window keeps focus beside it, and it claims the
keyboard from its next frame; the world panels are shown. Unlike a click it
does not walk your character up to it or turn the camera (a pet still turns
your character to face it once, as on a click). Any world panel: a window
or a terminal (`terminal.new`, `focus.get`). A hidden panel is refused ("the
panel is hidden …"). Esc twice (or a click on the world) gives the keyboard
back to the game.

### window.hide

```json
{"method": "window.hide", "params": {"id": 12, "hidden": true}}
```

`hidden` (required, true or false). A hidden panel is neither drawn nor
streamed: it loses the keyboard and full screen and sleeps at once, as an
unseen panel does after 30 s (a window stops acknowledging frames, so the
agent stops sending; a terminal detaches, unless a full-screen program runs
in it). `hidden: false` shows it again where its anchor puts it; it wakes and
glitches in when next drawn. Any world panel. It is lua/world.lua's `hidden`
flag (as `/term pin hide`), so pets close ranks while one is hidden.

### window.toggle_pet

```json
{"method": "window.toggle_pet", "params": {"id": 12}}
```

The title button next to pop-in: a pet becomes a pin right where it was last
shown (position and facing), anything else (a pin, `me`, `target`, `orbit`)
a pet. A size set on the panel stays. Any world panel. `/term pin toggle`
does it for the focused panel.

### window.place

```json
{"method": "window.place", "params": {"id": 12, "pin": "orbit 3.5"}}
```

Moves the panel as `/term pin ARGS` does on a focused window panel, keeping
its size. `"pet"` makes it a pet again.

### terminal.new

```json
{"method": "terminal.new", "params": {"profile": "pwsh", "pin": "here"}, "caller": "XivDesktop"}
```

Opens a world terminal, as `/term pet` does. Optional: `profile`, a name from
`CONFIG.profiles` or its place there counting from 1 (default: the default
profile); `pin`, as `window.open` takes it (default: a pet). The result in
`requests`: `{"id": panel}`, or why not: `no player (log in first)`, `no such
profile: …`, `pin: …`.

### focus.get

```json
{"method": "focus.get"}
```
```json
{"ok": true, "result": {"id": 12, "kind": "window"}}
```

The world panel with the keyboard: `kind` is `window` or `terminal`;
`{"id": 0}` when none has it.

### focus.cycle

```json
{"method": "focus.cycle", "params": {"dir": "next"}}
```

Gives the keyboard to the next (`"next"` or `1`, the default) or previous
(`"prev"` or `-1`) shown world panel after the focused one, in the order
they were opened, wrapping; hidden panels are skipped. With none focused,
`next` takes the first and `prev` the last. As `window.focus`: no walk-up, no
camera turn. The result in `requests`: `{"id": panel}`, or `no world panel
shown`.

### keys.reserve

```json
{"method": "keys.reserve", "params": {"chords": ["super+*", "alt+shift+q"]}, "caller": "XivDesktop"}
```

Keys this plugin reads for itself: while a remote window panel or a world
terminal has the keyboard, a key pressed with a chord's modifiers held is
not sent to the window (neither as KEY nor as text) and not typed into the
terminal. A chord is modifiers (`ctrl`, `shift`, `alt`, `super`) and a key
(a keymap name: `a`, `1`, `f5`, `enter`, `left`, `space`, …, or `*` for any
key) joined by `+`, case-insensitive; it matches whenever its modifiers are
held, whatever else is. `*` needs a modifier. The list replaces the
caller's earlier one (`caller` names it; without one, the list of callers
without a name); `[]` gives them back. At most 64 chords. The result in
`requests`: `{"chords": n}` (how many the caller holds now), or why a
chord was refused (`chord "hyper+x": unknown key …`; nothing changes then).
They add to `CONFIG.windows.reserved_chords` (lua/windows.lua, default
`{"super+*"}`). A reloaded plugin core forgets them: call again after
ghostty restarts (its `status` changes).

### agent.windows

```json
{"method": "agent.windows"}
```
```json
{"ok": true, "result": [
  {"wid": 7, "w": 800, "h": 600, "app": "firefox", "title": "Mozilla Firefox", "key": "", "extra": []},
  {"wid": 5, "w": 640, "h": 400, "app": "yad", "title": "Yad Window", "key": "yad-1", "extra": ["key:yad-1"]},
  {"wid": 0, "w": 0, "h": 0, "app": "", "title": "choose on the desktop", "key": "", "extra": []}
]}
```

The windows of the agent's last list (WLISTR), as it sent them (without
those on `CONFIG.windows.never`): `wid` for
`window.open`, the size, `app`, `title`. Columns a newer agent adds after the
title are passed through in `extra`; `key` is the one written `key:K` (or
`key=K`), else a plain first extra column, else `""`. A `wid` 0 entry says
what `window.open` without `run`, `match` or `wid` does. Empty until the
first list arrived.

### agent.windows.refresh

```json
{"method": "agent.windows.refresh"}
```

Asks the agent for its list again (WLIST). The answer arrives a moment later:
`agent.status`'s `window_lists` counts the lists received, so poll that (or
`agent.windows`) after the request's result shows in `window.list`.
`agent` may only be `"default"`. The Windows picker (`/window`) asks too.

### agent.apps

```json
{"method": "agent.apps"}
```
```json
{"ok": true, "result": [{"id": "foot", "name": "Foot", "icon": "foot", "categories": "System;TerminalEmulator;"}]}
```

The apps the agent can start, from `app` lines in its list, where a newer
agent sends them, without those on `CONFIG.windows.never` (so a launcher
built on this leaves them out too); `[]` otherwise. `icon` is a PNG path on
the agent's machine that may appear a moment after the list (the agent
renders icons in the background): look for it again later.

### agent.status

```json
{"method": "agent.status"}
```
```json
{"ok": true, "result": {"connected": true, "version": 3, "windows_ok": true, "agent": "127.0.0.1:7777", "window_lists": 2}}
```

`windows_ok`: connected to an agent that streams windows (protocol version 3).
`agent` is `""` when no agent is configured. `window_lists`: how many window
lists (WLISTR) have arrived.

### status

```json
{"method": "status"}
```
```json
{"ok": true, "result": "ghostty 3"}
```

The same text as `GhosttyDalamud.v1.Status` (the info bar entry and the
Umbra widget), without counting as the widget polling.

## Pieces

| Where | What |
| --- | --- |
| `shim/GhosttyDalamud/GhosttyIpc.cs`, `Native.cs` | registers `GhosttyDalamud.v1.Call` when `gu_call` exists; forwards the string (a pooled 64 KiB buffer) |
| `core/loader.nelua` | forwards `gu_call` to the running core; a JSON error without one |
| `core/host.nelua` | `gu_call` → `ipc_call`; `ipc_frame()` at the end of `gu_frame` |
| `core/app/ipc.nelua` | the lock, the call-side Lua state, the queue, the snapshot; `ghostty.window_*` for the core's Lua state |
| `lua/ipc.lua` | methods, parameter checks, running queued changes (`focus.cycle`'s order), the snapshot and `rev` |
| `lua/json.lua` | strict JSON |
| `core/app/remotewin.nelua` | `window_open / close / place / list`, the agent's last list (`winlist`), shared with `/window` |
| `core/app/worldview.nelua` | `world_panel_focus / hide`, `world_toggle_pet`, `world_terminal_new`, shared with the title buttons and `/term pin` |

## Verified

Host tests only (`tests/run.sh`): `tests/test_ipc.lua` (the JSON round trip
and its refusals; every method's checks against stubs; queued results and
`rev`) and `tests/test_ipc.nelua` (every method through `gu_call` against a
fake version 3 agent: WOPEN with `run:`, the caller in the log, WOPENED
turning a panel live, focus, place, failures in `requests`, focus without a
walk or camera turn and `focus.get`, hide (asleep, unplaced, refused focus)
and unhide, toggle_pet pinning at the pose it was shown at and back, WLIST
and a WLISTR with extra columns, a key and an app line through
`agent.windows`, `agent.apps` and `window.list`, `terminal.new` (a pet, a bad
profile, a pin), `focus.cycle` over a window and a terminal, WCLOSE,
malformed JSON, an unknown method, the queue limit, a response too large,
`/term reload`, `keys.reserve`, the `never` list filtering `agent.apps` and
`agent.windows`, and the channel gone after shutdown); `tests/test_loader.nelua`
(`gu_call` through the loader, with and without a core). The threading is by
design and review: the host build's lock is a no-op, as for the event queue.
**Not yet observed in game**, and no plugin has called it yet.
