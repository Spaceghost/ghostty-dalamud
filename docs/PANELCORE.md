# Panel core

**Status: plan only. Nothing here is implemented, built or observed in game.**

The goal is for XivDesktop and Ghostty to work together without either requiring the other. Both need
the same thing from the native core: the agent connection and the world panels that show the agent's
windows. This document names that part (`panelcore`), records where it is tangled with the terminal
today, and orders the work so every stage leaves `master` building and the tests green.

## What belongs in panelcore

| Keep in panelcore | Stays with the terminal |
| --- | --- |
| `core/protocol`, `core/agent_client`, `core/wincodec`, `core/wintex` | `core/ghostty` (libghostty-vt), `core/termview`, `core/render` |
| `core/world`, `core/ui`, `core/depthpass`, `core/hudmask`, `core/adopt` | `core/session` (PTY/ConPTY transports), `core/selection`, `core/links` |
| `core/app/remotewin`, `winpicker`, `panels`, `panelkit`, `adopt`, `worldview` (world part) | `core/app/terminal`, `views`, `dropdown`, `popup`, `inventory` |
| the `window.*`, `panel.*` and `agent.*` methods of `core/app/ipc` | the `term.*` methods |
| `core/policy` + `core/lua` (the Lua VM and `CONFIG.world`) | terminal profiles and key tables in `lua/` |

The measure of done for the split: a `ghostty_panelcore.dll` target that compiles and passes the world
and remote-window tests **without linking libghostty-vt**.

## Where it is tangled today

Found by reading the require graph and the modules; each is a stage below.

1. **A window panel is a `Session`.** `remotewin.nelua` creates its panels with
   `session_new_local('window', 60, 8)`: an ordinary terminal session of kind Window whose small local
   terminal draws the status text ("connecting", errors) through `draw_terminal`. Closing, focus, saving
   and the world list all go through `Session` and `close_terminal`.
2. **`core/app/state.nelua` is one record for everything.** It requires ghostty, termview, render,
   session and input, and every app module requires it, so nothing in `core/app` compiles without the
   terminal.
3. **The app layer is one require chain** (`state → agent → views → terminal → remotewin → … →
   worldview → lifecycle → hostsurface → host`), not a graph: `remotewin` requires `app.terminal` and
   `worldview` requires `app.dropdown`.
4. **Keyboard focus is claimed through the terminal** (`terminal_claim_keyboard`, `keychords` → `input`
   → ghostty key encoder).
5. **`ipc.nelua` mixes both method families** and reads terminal state for `panel.list`.
6. **One core per process** is enforced with a mutex and a fixed IPC name (`GhosttyDalamud.v1.*`).

## Stages

1. **Panel record.** Introduce `Panel` (id, kind, world placement, focus, close hook) in `core/world`.
   `Session` embeds it; the world list, focus and saving work on `*Panel`. No behaviour change.
2. **Status text without a terminal.** Draw a window panel's status lines with ImGui text in the
   world font, and stop creating a local terminal for kind Window. `remotewin` no longer needs
   `draw_terminal`.
3. **Split the state record** into `PanelHost` (host API, agent client, world, policy) and
   `TerminalHost` (sessions, views, render state). Terminal modules require both; panel modules only
   the first.
4. **Invert the chain.** `remotewin`, `panels`, `worldview` stop requiring terminal modules; the
   terminal registers itself with panelcore as a panel provider (draw, input, close, save). Keyboard
   focus becomes a panelcore arbiter that the terminal asks, instead of the reverse.
5. **Second build target** `ghostty_panelcore.dll` plus a test job that links it without libghostty-vt.
6. **Neutral IPC name.** Register `XivPanels.v1.Call` with the `window.*`, `panel.*`, `agent.*` methods;
   keep `GhosttyDalamud.v1.Call` as an alias.
7. **Later, not part of this plan's first pass:** XivDesktop ships panelcore, first-loaded plugin hosts
   it, and ownership hands over on unload (`adopt` already re-adopts the agent's windows after a
   reload, which is what makes the handover cheap). Until then XivDesktop still needs Ghostty loaded.

Stages 1 to 4 are refactors inside one DLL and can each be verified by the existing host tests plus an
in-game check of terminals, window panels, focus and `/term reload`. Stage 5 is where the claim
"panelcore does not need the terminal" becomes checkable.
