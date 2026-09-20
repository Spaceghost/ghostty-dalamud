# Ghostty for Dalamud

**A real terminal, inside FINAL FANTASY XIV.**

Run a shell in a drop-down, open a floating terminal, or place a terminal panel
in the game world. Ghostty for Dalamud combines **libghostty-vt**, a **Nelua
native core**, **Lua configuration**, and a thin **C# Dalamud adapter**. An
optional Umbra widget opens the same terminal; it does not run a second core.

> **Status: experimental developer preview.** This is an independent project,
> not an official Ghostty project. Official Dalamud-list acceptance is not
> established. Host-side tests do not certify an in-game session, native
> Windows, Wine, macOS, or controller support. Start with a plain terminal;
> treat world rendering and controller behavior as separate things to test.
> See [release readiness](docs/RELEASE_READINESS.md).

[Quick start](#quick-start) · [Commands](#commands-and-input) ·
[Configuration](#configuration-and-transports) ·
[Troubleshooting](#troubleshooting) · [Architecture](docs/ARCHITECTURE.md)

## What you get

| Capability | What it means |
| --- | --- |
| Drop-down and floating terminals | Shell sessions rendered into Dalamud's ImGui draw lists, with tabs, selection, clipboard input and zoom. |
| World panels | Pin a terminal in place or let one follow your character. Placement, occlusion and lighting remain experimental. |
| Lua configuration | Profiles, appearance, keymaps and behavior, with user overrides outside the checkout. Lua is trusted code, not a sandbox. |
| Two execution paths | A POSIX host agent for Wine, or local Windows ConPTY. SSH runs inside a shell; it is not a third terminal transport. |
| Optional Umbra integration | A toolbar entry backed by the standalone plugin's IPC. Umbra is not required for the terminal. |

## How it fits together

```text
FINAL FANTASY XIV / Dalamud
  GhosttyDalamud.dll       C# adapter: game services, input, plugin IPC
    ghostty_loader.dll    development loading and native hot reload
      ghostty_core.dll    libghostty-vt + rendering + transports + Lua
        |
        +-- Wine -------- TCP + token ------ ghostty-agent on the POSIX host
        |                                    `-- shell / optional tmux / ssh
        `-- Windows ----- local ConPTY ----- PowerShell / cmd

Umbra.Ghostty.dll -- optional IPC client --> GhosttyDalamud.dll
```

The terminal displays a program; it does not restrict what that program can
do. Agent sessions run with the host agent's privileges. ConPTY sessions run
with the local process's privileges.

**Companion boundaries.** [Almanac](https://github.com/Spaceghost/almanac-dalamud)
owns model/chat orchestration; [XivMcp](https://github.com/Spaceghost/xivmcp-dalamud)
owns MCP game tools and their permissions.
[XivDesktop](https://github.com/Spaceghost/xivdesktop-dalamud) is a separate
app launcher that needs Ghostty's newer window/compositor capabilities.
This checkout's basic terminal is not evidence that those capabilities, a
native `/ask` adapter, or another branch's release packaging are available.
Use the documentation belonging to the exact build you install.

## Requirements

The complete plugin build uses **Linux** with Git, Bash, a C compiler, Make,
Python 3.10+, curl, ar and sha256sum, plus the Zig version and .NET SDK channel
in [`toolchain.env`](toolchain.env). Build and reference-assembly details live
in [`tools/build.sh`](tools/build.sh) and
[`tools/fetch-vendor.sh`](tools/fetch-vendor.sh).

| Environment | Execution path and limits |
| --- | --- |
| Linux + XIVLauncher.Core/Wine | Build on Linux; run `ghostty-agent` on the host. The installer prints a Wine `Z:` DLL path. |
| Native Windows | Use a separately validated complete plugin build and local ConPTY. These shell scripts are not a native Windows build/installation workflow. |
| macOS | Agent support is experimental; this is not a supported full-plugin build host. |

Pinned build references do **not** update your installed Dalamud. A successful
compile against them does not establish compatibility with your running game.

## Quick start

### 1. Build from source

```sh
git clone https://github.com/Spaceghost/ghostty-dalamud.git
cd ghostty-dalamud
tools/fetch-vendor.sh
tools/build.sh
```

Dependencies are fetched at the revisions in `toolchain.env`. The build must
build Nelua's interpreter; the checked-in launcher alone is not sufficient.
Dalamud references are verified before extraction and cached files are checked
before reuse. Do not bypass a failed integrity check.

The plugin output is `build/dist/GhosttyDalamud/`. Keep the managed DLL,
manifest, native DLLs and `lua/` together. The host agent and optional widget
are separate outputs under `build/dist/`. Do not package game, Dalamud or
Umbra reference assemblies with the plugin.

### 2. Start the agent on the Wine host

In a separate host terminal, from the checkout:

```sh
build/dist/ghostty-agent --listen 127.0.0.1:7777
```

Leave it running. It creates its token file on first start. The plugin's agent
profile must use the matching token file and address. **Skip this step for a
native Windows terminal using ConPTY.** A remote agent needs explicit
configuration and a protected connection; see [security](#privacy-and-security).

### 3. Stage and enable the plugin

From the checkout, in another host terminal:

```sh
tools/install-dev.sh
```

By default this stages to `build/dev-plugin/GhosttyDalamud/` inside the
checkout; `GHOSTTY_DEV_PLUGIN_DIR` overrides it. The script prints the actual
Wine DLL path. It does not edit Dalamud's configuration or files under
`~/.xlcore`.

1. `/xlsettings` → **Experimental** → **Dev Plugin Locations**: add the printed
   `GhosttyDalamud.dll` path, then save and close.
2. `/xlplugins` → **Dev Tools** → **Installed Dev Plugins**: enable the plugin
   and its load-on-boot option. Adding a path alone does not enable a dev plugin.
3. `/term` opens the terminal. Pick a profile appropriate to the host.

On native Windows, register the actual Windows path to the DLL in a complete,
validated plugin folder instead of using the Wine staging script.

### 4. Check the first session

Inside a POSIX terminal, run:

```sh
printf 'hello from the host\n'
```

In a PowerShell profile, use `Write-Output 'hello from Windows'` instead.
The check is complete when the text appears **and the shell prompt returns**.
An empty terminal window only proves that the UI opened, not that a shell
connected. These are checks to perform on your machine, not claimed test results.

Rebuild and run `tools/install-dev.sh` again to update. `/term reload` rereads
configuration; `/term reload-core` requests a native-core reload. Changes to
the managed plugin or loader may require a plugin reload or game restart;
read the installer's output before assuming a native hot reload was enough.
The installer preserves an existing staged `lua/init.lua` and reports when
it differs from the shipped version.

## Commands and input

`/term` also has the aliases `/tomestone` and `/tome`.

| Command | Purpose |
| --- | --- |
| `/term`, `/term toggle` | Show or hide the drop-down. |
| `/term new [n]`, `/term window [n]` | New tab or floating window using profile n. |
| `/term pin [here\|me\|target\|orbit]`, `/term unpin` | Place or remove a world panel. |
| `/term pet` | Create a following world panel. |
| `/term occluded on\|off` | Control whether a hidden world terminal keeps running. |
| `/term min [id]`, `/term restore [id]`, `/term focus id` | Manage terminal visibility. |
| `/term send [#id] text`, `/term type [#id] text` | Send terminal input with or without Enter. |
| `/term bell [style]` | Preview a visual bell. |
| `/term showcase`, `/term showcase off` | Start or stop screenshot demonstrations. |
| `/term config`, `/term reload` | Edit or reload configuration. |
| `/term reload-core` | Request a native-core reload through the development loader. |

Default keys are **Ctrl+backquote** for the drop-down and
**Ctrl+Shift+backquote** for world panels. Ctrl+Shift+C/V copies/pastes,
Ctrl+Shift+T/W opens/closes tabs, Ctrl+Tab changes tabs, and Ctrl+=/-/0 changes
zoom. Mouse selection may copy automatically according to `copy_on_select`.
The authoritative bindings are in [`lua/keymap.lua`](lua/keymap.lua).

The info-bar entry opens the drop-down on click, the popup on right-click, a
window on Shift+click, and world screens on Ctrl+click.

Controller gestures default to the game's `select` button: tap to toggle,
hold to advance, double-tap to go back. On DualSense this is the touchpad click,
not Create. The optional `create` setting uses Windows HID reports; its
Wine/controller behavior is unverified. The normal default does not open a HID
device. An empty controller setting disables the handling.

## Configuration and transports

User configuration belongs in
`<Dalamud config>/pluginConfigs/GhosttyDalamud/`, not in the source checkout.
Typical launcher roots are `%APPDATA%\XIVLauncher` on Windows and `~/.xlcore`
with XIVLauncher.Core; the actual paths come from Dalamud.

Use `/term config` for settings saved to `settings.lua`. For larger overrides,
copy [`lua/init.lua`](lua/init.lua) or [`lua/keymap.lua`](lua/keymap.lua) into
the configuration directory's `lua/`. User modules take precedence over shipped
ones. Reload with `/term reload`. Preserved overrides can retain old defaults:
a rebuild does not silently reset your profile.

| Transport/profile | What to configure |
| --- | --- |
| Agent | Running agent, matching token file, IPv4 address and port. `localhost` maps to loopback; arbitrary DNS names and IPv6 are not implemented in this transport. Sessions can survive a disconnect while the agent remains running. |
| ConPTY | A local Windows shell such as PowerShell or cmd. No host agent is needed; process-failure, large-input and shutdown behavior still need target tests. |
| tmux / SSH | Executables inside a shell; install them separately. For remote agent access, use a protected tunnel such as `ssh -L`. |
| Superlogical | Placeholder, not a working integration. |

The shipped local-agent profile uses a per-user token file and an empty inline
token. Do not paste credentials into shipped Lua files or commit them.

### Build and staging overrides

| Variable | Purpose |
| --- | --- |
| `ZIG`, `DOTNET`, `CC`, `JOBS` | Tool paths and build concurrency. |
| `DALAMUD_LIB_PATH` | Explicit local reference assemblies, outside bundle verification. |
| `UMBRA_LIB_PATH` | Umbra references; otherwise the pinned vendor distribution. |
| `SKIP_UMBRA=1` | Build without the optional widget. |
| `SKIP_SHIM=1` | Rebuild native/Lua components using existing managed outputs. |
| `SKIP_WIN=1` | Host components only, without Windows native binaries. |
| `SKIP_DEPS=1` | Reuse dependency builds; not suitable for a clean checkout. |
| `GHOSTTY_DEV_PLUGIN_DIR`, `UMBRA_WIDGET_DLL` | Development staging destinations. |

For Umbra, build the widget, run `tools/install-dev.sh --widget`, add the
staged `Umbra.Ghostty.dll` in **Umbra Settings → Plugins**, then add its toolbar
widget. The standalone terminal is designed to work without it.

## Troubleshooting

| Symptom | Check first |
| --- | --- |
| `/term` is unknown | Confirm the DLL location, enable the dev plugin in `/xlplugins`, and inspect the Dalamud log for `GhosttyDalamud`. A registered path is not a loaded plugin. |
| The terminal opens but no prompt appears | On Wine, check the foreground agent, IPv4 address, port and token file. On Windows, check that the selected profile uses an available ConPTY shell. |
| Settings do not change after a rebuild | Check user overrides and the preserved staged `lua/init.lua`; use `/term reload`. Back up overrides before changing them. |
| A native DLL cannot load | Keep the complete output folder together. Check build/runtime compatibility and the plugin log, not just the presence of the managed DLL. |
| A verified dependency/cache is rejected | Inspect the error and intentionally move the suspect cache aside before refetching. Do not disable verification to make the build green. |
| The widget is missing | Build without `SKIP_UMBRA`, stage with `--widget`, and register the widget with Umbra rather than as a second terminal plugin. |

For a useful issue, include the source commit, OS, native-Windows/Wine choice,
Dalamud version, selected transport, exact reproduction steps and a redacted
log excerpt. Do not upload your token file or whole configuration directory.

## Experimental rendering

World placement, animation, lighting and occlusion need in-game validation.
Shadow boards are **off by default** and call a game function resolved by
signature. A game patch can invalidate that function. Keep them off until the
specific game/Dalamud combination has been tested.

`/term showcase` is a demonstration command, not a compatibility test. A useful
screenshot records its build and environment and contains no private terminal
output. A screenshot demonstrates that captured moment, not compatibility
across game versions or platforms.

## Privacy and security

**The agent stream is not encrypted.** A token authenticates; it does not encrypt.
Keep the agent on loopback or use a protected tunnel. Do not expose its listener
to the public internet. A terminal can execute commands with the agent or game
process's privileges, and Lua overrides are trusted executable code.

Clipboard content, terminal output, logs, settings and migration copies can
contain private data. Review them before sharing screenshots or diagnostics.
Release binaries and PDBs also need review for build paths and metadata.

Migration from the previous Umbra-hosted layout is implemented in
[`lua/migrate.lua`](lua/migrate.lua). Back up old configuration before testing
it; inspect the migration result before deleting any backup.

## Development and evidence

From a built checkout, run the host-side suites:

```sh
python3 -m unittest discover -s tests -p 'test_*.py' -v
vendor/nelua-lang/nelua-lua tests/test_defaults.lua
tests/run.sh
```

Record the exact commit and actual results. A passing host suite does not prove
that the plugin loaded, that a shell connected, that a world panel rendered, or
that a controller worked. Those need separate target-environment observations.
See [architecture](docs/ARCHITECTURE.md) and
[release readiness](docs/RELEASE_READINESS.md) before publishing a build.

## Contributing and attribution

Maintained by [Spaceghost](https://github.com/Spaceghost).
[Feature voting](https://spacegho.st/mods/ffxiv/term/vote/) is also linked in the
in-game About screen; its idea catalogue ships with the plugin rather than
being fetched in the background. Use the repository's
[issues](https://github.com/Spaceghost/ghostty-dalamud/issues) for reproducible bugs.

Built on Ghostty/libghostty-vt, Nelua, Lua, Dalamud, gc-cimgui,
FFXIVClientStructs and Umbra. Preserve dependency licenses and contributor
attribution. Dependency licenses do not establish this project's license or
Dalamud approval. Maintainer-only identity setup is in
`tools/configure-identity.sh`; contributors should keep their chosen attribution.
Editing current documentation does not remove old versions or commit metadata;
history cleanup is a separate operation.
