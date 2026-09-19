# IPC for other plugins

`GhosttyDalamud.v1.Call` lets another Dalamud plugin (XivDesktop, for one)
list, open, close, focus and place remote-window panels
([REMOTE_WINDOWS.md](REMOTE_WINDOWS.md)). It is one Dalamud call gate:
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
* **Reads** (`window.list`, `agent.status`, `status`) answer at once from a
  snapshot the frame publishes at its end. They are at most one frame old.
* **Changes** (`window.open`, `window.close`, `window.focus`,
  `window.place`) are checked, given a request id and queued. The response
  says only that: `{"queued": true, "request": 1726732800001}`. At the end of
  the next frame ghostty runs them in order, in its own Lua state, through
  the same functions as `/window` (`core/app/remotewin.nelua`: `window_open`,
  `window_close`, `window_focus`, `window_place`). The outcome shows in
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
     "state": "live", "kind": "pet", "focused": false}
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
* `focused`: the panel has the keyboard.
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
(log in first)`, `pin: …`. A window the agent then refuses shows as `ended`
with the reason on the panel.

### window.close

```json
{"method": "window.close", "params": {"id": 12}}
```

Closes the panel (it glitches out) and its stream.

### window.focus

```json
{"method": "window.focus", "params": {"id": 12}}
```

Gives the panel the keyboard and shows the world panels, as a click would.
Esc twice (or a click on the world) gives it back to the game.

### window.place

```json
{"method": "window.place", "params": {"id": 12, "pin": "orbit 3.5"}}
```

Moves the panel as `/term pin ARGS` does on a focused window panel, keeping
its size. `"pet"` makes it a pet again.

### agent.status

```json
{"method": "agent.status"}
```
```json
{"ok": true, "result": {"connected": true, "version": 3, "windows_ok": true, "agent": "127.0.0.1:7777"}}
```

`windows_ok`: connected to an agent that streams windows (protocol version 3).
`agent` is `""` when no agent is configured.

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
| `lua/ipc.lua` | methods, parameter checks, running queued changes, the snapshot and `rev` |
| `lua/json.lua` | strict JSON |
| `core/app/remotewin.nelua` | `window_open / close / focus / place / list`, shared with `/window` |

## Verified

Host tests only (`tests/run.sh`): `tests/test_ipc.lua` (the JSON round trip
and its refusals; every method's checks against stubs; queued results and
`rev`) and `tests/test_ipc.nelua` (every method through `gu_call` against a
fake version 3 agent: WOPEN with `run:`, the caller in the log, WOPENED
turning a panel live, focus, place, failures in `requests`, WCLOSE, malformed
JSON, an unknown method, the queue limit, a response too large, `/term
reload`, and the channel gone after shutdown); `tests/test_loader.nelua`
(`gu_call` through the loader, with and without a core). The threading is by
design and review: the host build's lock is a no-op, as for the event queue.
**Not yet observed in game**, and no plugin has called it yet.
