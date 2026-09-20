# Windows

Ghostty for Dalamud is built on Linux and runs in the game on Windows. This
file is the Windows half of the story in one place: what runs where, how a
player installs it, how a developer builds and tests it, which transports are
used and why, and — kept apart on purpose — what has actually been observed
versus what has only been compiled.

> **Status.** Everything in this file is built by cross-compiling from Linux.
> The parts marked *not observed* have never run on a real Windows machine
> from this checkout. That is a statement about evidence, not a guess about
> whether they work; the smoke tests below exist so a Windows machine can
> settle it.

## What runs where

| Piece | Where it runs on a Windows player's machine |
|---|---|
| `GhosttyDalamud.dll` (C# shim) | in the game, loaded by Dalamud; no logic of its own |
| `ghostty_loader.dll`, `ghostty_core.dll` (Nelua) | in the game process; the loader swaps a new core in when the file changes |
| `lua/` (policy) | in the core's Lua state, from the plugin folder or your config directory |
| `ghostty-agent.exe` | a normal user process, usually on the same machine; shells survive the game |
| the assistant (`almanac`) | wherever the transport puts it: the agent's machine, or the game's machine for a local session |

Native Windows and Wine/Proton are different platforms to the plugin:
`ghostty.platform()` answers `'windows'` or `'wine'`, and `lua/platform.lua`
picks the agent token path and the default profiles from that. Under
Wine/Proton the agent is the Linux one and nothing in this file about
`ghostty-agent.exe` applies.

## For a player

Installing the plugin and running `ghostty-agent.exe` are in the README
([Windows](../README.md#windows)). Two things that are only about Windows:

### The `/ask` panel and almanac

`/ask` runs `CONFIG.assistant.stream` (by default `almanac ask
--stream-json`) and reads one JSON object per line. almanac is a separate
project and a Python one, so a Windows player has three ways to have it:

1. **Install almanac on this machine**, so that `almanac` is on `PATH` for the
   user who runs the game. Nothing else to configure.
2. **Run it where you already have it.** Run `ghostty-agent` on that machine
   (Linux, macOS or another Windows box), point `CONFIG.agent` at it
   (`host`, `port`, `token_file`) and set `CONFIG.assistant.transport =
   'agent'`. The question and the answer travel over the agent connection;
   almanac's threads live on that machine.
3. **Use another assistant.** `CONFIG.assistant.stream` and `.threads` are
   argv lists: anything that prints the same JSON lines works. `/ask term`
   opens a plain terminal running `CONFIG.assistant.chat` / `.ask` instead,
   which has no JSON protocol at all.

When the command is not there, the panel says so and names these three ways
(`lua/assistant.lua`, `A.not_found_text`); nothing silently does nothing.

### A user name with non-ASCII characters

Windows paths under `C:\Users\<name>` reach the plugin as UTF-8. The Win32
"ANSI" functions read such a path in the active code page, which cannot spell
most names, so every path the core uses goes through the wide (UTF-16) API:
`core/sys/winpath.nelua` converts, and the plugin folder, the config
directory, `lua/init.lua`, the fallback fonts, the screenshot folders and the
gallery's file listing all use it. This is compiled but *not observed* on a
Windows machine with such a name; `tests/smoke_winpath_windows.nelua` is the
test that would settle it.

## Transports on Windows

There are four, and which one a terminal or the `/ask` panel uses is decided
by the profile (`lua/platform.lua`) and by what is answering:

| Transport | What it is | Used for |
|---|---|---|
| `agent` | a PTY session on `ghostty-agent(.exe)` | terminals; shells outlive the game |
| `job` | a process on **pipes** on the agent (docs/JOBS.md, protocol version 4) | the `/ask` panel through an agent |
| `pipe` | a local process on **pipes** in the game process (`core/sys/procpipe.nelua`) | the `/ask` panel with no agent answering |
| `conpty` | a local pseudo console in the game process | local terminals (`powershell (local)`, `cmd (local)`) |

**Why the panel never uses a pseudo console.** A ConPTY is a screen: what a
program writes goes through a console screen buffer that is re-emitted as VT,
so a line longer than the console is wrapped into rows and comes back with
CR/LF (and cursor moves) inserted in the middle of it. That is right for a
terminal and wrong for `--stream-json`, where a single JSON object can be
thousands of characters long — it would arrive in pieces and fail to parse.
Both of the panel's transports are therefore pipes, which have no width and no
screen. `tests/test_procpipe.nelua` runs a 4000-character line through the
local one on Linux and checks it byte for byte;
`tests/smoke_procpipe_windows.nelua` is the same check for the Windows half.

**Degrading.** The panel asks the agent for a job only when the agent greets
with protocol version 4. An older agent, or an agent that refuses the job,
gets the same command as a PTY session instead, so the panel keeps working —
with a console's reflow risk on a Windows agent, which is why the job runner
matters. `agent/job_windows.nelua` is where the Windows agent's job runner
lives.

## For a developer

### Building the Windows artifacts (from Linux)

Everything is cross-compiled; there is no Windows build host and none is
needed. `tools/build.sh` produces, with Zig as the C compiler
(`tools/zig-cc-win.sh` = `zig cc -target x86_64-windows-gnu`) and the .NET SDK
for the C# shim:

| Artifact | Built by | Needs |
|---|---|---|
| `build/dist/ghostty_core.dll` | Nelua -> C -> `zig cc` | libghostty-vt and Lua, both cross-built for Windows |
| `build/dist/ghostty_loader.dll` | the same | — |
| `build/dist/ghostty-agent.exe` | the same | — |
| `build/dist/GhosttyDalamud.dll` | `dotnet build` | Dalamud reference assemblies |
| `build/dist/GhosttyDalamud/` | assembled by the script | all of the above plus `lua/`, `themes/`, `fonts/` |

```sh
tools/fetch-vendor.sh                     # once
tools/build.sh                            # everything
SKIP_SHIM=1 tools/build.sh                # native only, no dotnet
SKIP_DEPS=1 SKIP_SHIM=1 tools/build.sh    # reuse the Nelua/libghostty-vt/Lua builds
tools/package.sh                          # the zips a player installs
```

The Windows-only source is selected at compile time with
`## if ccinfo.is_windows then`, so a host build compiles the POSIX half of the
same files and the tests exercise that. Two consequences worth knowing:

* A file that only exists on the Windows side still has to compile for the
  host — hence the stubs and POSIX halves in `core/sys/conpty.nelua`,
  `core/sys/procpipe.nelua`, `core/sys/winpath.nelua`,
  `agent/job_windows.nelua`.
* A host test never touches a Win32 call. Anything that must be proven against
  the real API belongs in a smoke test built for Windows.

### Testing

```sh
tests/run.sh          # the host suite; must print ALL OK
```

What it covers for Windows is the platform-independent half: profile and
transport choice (`test_platform`, `test_assistant`), the `/ask` panel and its
transports including a real child process on pipes (`test_ask`,
`test_procpipe`), the agent's protocol and logic (`test_agent*`, `test_jobs`),
UTF-8 path handling (`test_winpath`), the Win32 command line quoting
(`test_agent_windows`).

The Windows-only tests are built for Windows and run there by hand. They are
not part of `tests/run.sh` and nothing on Linux runs them:

| Test | What only Windows can show |
|---|---|
| `tests/smoke_agent_windows.nelua` | a real `ghostty-agent.exe`: ConPTY sessions, reattach, clipboard, job objects |
| `tests/smoke_windows_win32.nelua` | the plugin's Windows side against a running agent |
| `tests/smoke_capture_win32.nelua` | Win32 window capture |
| `tests/smoke_procpipe_windows.nelua` | the local pipe transport: a long line unwrapped, stdin EOF, kill-on-close |
| `tests/smoke_winpath_windows.nelua` | the wide-path conversions and folder lookups, ideally under a non-ASCII user name |

Each file's header comment has its exact build and run command.

### Debugging in game

`/term selftest` runs the core's own checks and prints the build stamp
(`core/buildinfo.nelua`). Dalamud's log has everything the core logs; the
plugin's Settings window shows the agent connection and the plugin status.
A new `ghostty_core.dll` in the plugin folder is picked up within about two
seconds without restarting the game.

## Known gaps on Windows

* **Nothing here has been run in the game on Windows.** The whole Windows
  surface is compiled and unit-tested on Linux.
* **The Windows agent's job runner.** Until `agent/job_windows.nelua` is
  implemented, a Windows agent refuses `JOPEN` and the `/ask` panel falls back
  to a PTY session there, where a long JSON line can be reflowed by the
  console.
* **Lua's own file access is still ANSI.** The Lua modules write their state
  files (`settings.lua`, `world-state.lua`, `ask-state.lua`, ...) with
  `io.open`, which is the CRT's ANSI open. Under a config directory whose path
  the active code page cannot spell, those writes fail. The core's own reads
  no longer do (`core/sys/winpath.nelua`).
* **No Wayland on Windows.** The agent's compositor features
  (`--windows wayland`, remote desktop windows from a Linux host) are POSIX
  only; a Windows agent uses `--windows win32` and says so if asked for
  anything else.
